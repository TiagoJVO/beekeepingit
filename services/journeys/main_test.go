// Package main — integration tests for #45 (EPIC-04 M4, FR-JO-4, FR-TEN-2,
// FR-HIS-1, D-21): the migrated schema shape (tenancy: every owned table
// carries organization_id), the REST create/edit/close/delete surface, the
// internal sync validate/apply endpoints (journey + journey_plan_item ops),
// and cross-org IDOR regressions. Uses a real, containerized Postgres
// (testcontainers), mirroring services/activities/main_test.go's own fixture
// conventions.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/journeys/api"
	"github.com/TiagoJVO/beekeepingit/services/journeys/store"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/journeys/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

// testOrgHeader lets a test request stand in as a caller resolved to a
// different org/user/role than the devseed default — mirrors
// activities/main_test.go's identical helper.
const testOrgHeader = "X-Test-Org-Claims"

func injectClaims(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims := authn.Claims{
			Sub:            devseed.OidcSub,
			UserID:         devseed.UserID,
			OrganizationID: devseed.OrganizationID,
			Role:           devseed.MembershipRole,
		}
		if override := r.Header.Get(testOrgHeader); override != "" {
			parts := strings.SplitN(override, "|", 4)
			if len(parts) == 4 {
				claims = authn.Claims{Sub: parts[0], UserID: parts[1], OrganizationID: parts[2], Role: parts[3]}
			}
		}
		ctx := authn.ContextWithClaims(r.Context(), claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type journeysFixture struct {
	srv      *servicetemplate.Server
	pool     *pgxpool.Pool
	apiaries *fakeApiaries
}

// fakeApiaries stands in for the real apiaries service's GET /v1/apiaries/{id}
// — 200 for any id in `known`, 404 otherwise — mirroring
// activities/main_test.go's identical fixture, including its per-id hit
// counting (proves the batch write path de-duplicates its ownership calls).
type fakeApiaries struct {
	server *httptest.Server
	mu     sync.Mutex
	hits   map[string]int
}

func (f *fakeApiaries) hitCount(apiaryID string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[apiaryID]
}

func newFakeApiaries(t *testing.T, known map[string]bool) *fakeApiaries {
	t.Helper()
	f := &fakeApiaries{hits: map[string]int{}}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/v1/apiaries/")
		f.mu.Lock()
		f.hits[id]++
		f.mu.Unlock()
		if known[id] {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(f.server.Close)
	return f
}

func newJourneysFixture(t *testing.T, knownApiaryIDs ...string) *journeysFixture {
	t.Helper()
	ctx := context.Background()

	known := make(map[string]bool, len(knownApiaryIDs))
	for _, id := range knownApiaryIDs {
		known[id] = true
	}
	fakeApiaries := newFakeApiaries(t, known)
	verifier, err := api.NewApiaryVerifier(fakeApiaries.server.URL, fakeApiaries.server.Client())
	if err != nil {
		t.Fatalf("NewApiaryVerifier: %v", err)
	}
	const (
		dbUser = "beekeepingit_test"
		dbPass = "beekeepingit_test"
		dbName = "beekeepingit_test"
	)
	pg, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithUsername(dbUser),
		tcpostgres.WithPassword(dbPass),
		tcpostgres.WithDatabase(dbName),
		tcpostgres.BasicWaitStrategies(),
	)
	if err != nil {
		t.Fatalf("start postgres container: %v", err)
	}
	t.Cleanup(func() {
		if err := pg.Terminate(ctx); err != nil {
			t.Logf("terminate postgres container: %v", err)
		}
	})
	host, err := pg.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := pg.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}

	dbCfg := dbaccess.Config{Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable"}
	createSchema(ctx, t, dbCfg, "journeys")
	dbCfg.SearchPath = "journeys"
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	cfg := config.Config{ServiceName: "journeys-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })
	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/v1/journeys", injectClaims(api.Router(pool, verifier)))
	srv.Mount("/internal/sync", injectClaims(api.InternalSyncRouter(pool, verifier)))

	return &journeysFixture{srv: srv, pool: pool, apiaries: fakeApiaries}
}

func (f *journeysFixture) do(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return f.doAs(t, "", method, path, body)
}

func (f *journeysFixture) doAs(t *testing.T, callerHeader, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		r = bytes.NewReader(b)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, r)
	if callerHeader != "" {
		req.Header.Set(testOrgHeader, callerHeader)
	}
	f.srv.Router().ServeHTTP(rec, req)
	return rec
}

func callerClaims(sub, userID, orgID, role string) string {
	return strings.Join([]string{sub, userID, orgID, role}, "|")
}

// otherOrgCaller mirrors activities/main_test.go's fixed org-B principal.
func otherOrgCaller() string {
	return callerClaims(
		"22222222-2222-4222-8222-222222222222",
		"a0000000-0000-7000-8000-000000000002",
		"b0000000-0000-7000-8000-000000000002",
		"admin",
	)
}

func createSchema(ctx context.Context, t *testing.T, cfg dbaccess.Config, name string) {
	t.Helper()
	conn, err := pgx.Connect(ctx, cfg.DSN())
	if err != nil {
		t.Fatalf("connect to create schema: %v", err)
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS "+name); err != nil {
		t.Fatalf("create schema %s: %v", name, err)
	}
}

func newUUID(t *testing.T) pgtype.UUID {
	t.Helper()
	return pgtype.UUID{Bytes: uuid.New(), Valid: true}
}

func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

func devseedOrg() pgtype.UUID {
	return pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
}

// --- Tenancy schema check (FR-TEN-2) ---

func TestJourneysSchema_EveryOwnedTableCarriesOrganizationID(t *testing.T) {
	f := newJourneysFixture(t)
	unscoped, err := dbaccess.UnscopedTables(context.Background(), f.pool, "journeys")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(unscoped) != 0 {
		t.Fatalf("tables missing organization_id = %v, want none (every owned table must carry organization_id, FR-TEN-2)", unscoped)
	}
}

func TestJourneysMigration_FourTablesCreated(t *testing.T) {
	f := newJourneysFixture(t)
	for _, table := range []string{"journeys", "journey_plan_items", "audit_log", "sync_conflict_log"} {
		var exists bool
		err := f.pool.QueryRow(context.Background(), `
			SELECT EXISTS (
				SELECT 1 FROM information_schema.tables
				WHERE table_schema = 'journeys' AND table_name = $1
			)`, table).Scan(&exists)
		if err != nil {
			t.Fatalf("query information_schema.tables for %s: %v", table, err)
		}
		if !exists {
			t.Fatalf("journeys.%s table does not exist", table)
		}
	}
}

func TestJourneysMigration_OrganizationIDNotNull(t *testing.T) {
	f := newJourneysFixture(t)
	_, err := f.pool.Exec(context.Background(), `
		INSERT INTO journeys.journeys (id, name, main_activity_type, updated_at)
		VALUES (gen_random_uuid(), 'x', 'generic', now())`)
	if err == nil {
		t.Fatalf("insert with NULL organization_id unexpectedly succeeded — NOT NULL constraint not enforced (FR-TEN-2)")
	}
}

// --- POST /v1/journeys (FR-JO-4) ---

func decodeProblem(t *testing.T, rec *httptest.ResponseRecorder) struct {
	Errors []struct {
		Field string `json:"field"`
		Code  string `json:"code"`
	} `json:"errors"`
} {
	t.Helper()
	var p struct {
		Errors []struct {
			Field string `json:"field"`
			Code  string `json:"code"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode problem response: %v, body = %s", err, rec.Body.String())
	}
	return p
}

func problemHasFieldCode(p struct {
	Errors []struct {
		Field string `json:"field"`
		Code  string `json:"code"`
	} `json:"errors"`
}, field, code string) bool {
	for _, e := range p.Errors {
		if e.Field == field && e.Code == code {
			return true
		}
	}
	return false
}

type journeyResponse struct {
	ID               string   `json:"id"`
	OrganizationID   string   `json:"organization_id"`
	Name             string   `json:"name"`
	MainActivityType string   `json:"main_activity_type"`
	Status           string   `json:"status"`
	ApiaryIDs        []string `json:"apiary_ids"`
}

func createBody(id, name, mainActivityType string, apiaryIDs []string) map[string]any {
	return map[string]any{
		"id": id, "name": name, "main_activity_type": mainActivityType, "apiary_ids": apiaryIDs,
	}
}

func TestJourneysRest_Create_Success(t *testing.T) {
	apiaryA, apiaryB := uuid.NewString(), uuid.NewString()
	f := newJourneysFixture(t, apiaryA, apiaryB)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Colheita de Primavera", "harvest", []string{apiaryA, apiaryB}))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got journeyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v, body = %s", err, rec.Body.String())
	}
	if got.ID != id || got.Name != "Colheita de Primavera" || got.MainActivityType != "harvest" || got.Status != "open" {
		t.Fatalf("created journey = %+v, want id=%s name status=open type=harvest", got, id)
	}
	if len(got.ApiaryIDs) != 2 {
		t.Fatalf("apiary_ids = %v, want 2 entries", got.ApiaryIDs)
	}
}

// TestJourneysRest_Create_CrossOrgApiaryIdIsRejected is the CRITICAL test
// this service's plan-items write path exists to enforce (mirrors
// activities'/apiaries' own #38/#284 carry-over): an apiary_id that doesn't
// belong to the caller's org must never be accepted, and nothing must be
// written.
func TestJourneysRest_Create_CrossOrgApiaryIdIsRejected(t *testing.T) {
	foreignApiaryID := uuid.NewString()
	f := newJourneysFixture(t) // no known apiary ids at all
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "generic", []string{foreignApiaryID}))
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org/unknown apiary_id must be rejected), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "apiary_ids[0]", "not_found") {
		t.Fatalf("problem errors = %+v, want apiary_ids[0]/not_found", p.Errors)
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}}); err == nil {
		t.Fatalf("GetJourney found a row after a rejected cross-org create — the write must not have happened")
	}
}

func TestJourneysRest_Create_IdempotentReplayDoesNotDuplicate(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	body := createBody(id, "Journey", "harvest", []string{apiaryID})

	first := f.do(t, http.MethodPost, "/v1/journeys", body)
	if first.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	second := f.do(t, http.MethodPost, "/v1/journeys", body)
	if second.Code != http.StatusCreated {
		t.Fatalf("replayed create status = %d, want 201 (idempotent replay), body = %s", second.Code, second.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListJourneysByOrg(context.Background(), sqlcgen.ListJourneysByOrgParams{OrganizationID: devseedOrg(), Limit: 50})
	if err != nil {
		t.Fatalf("ListJourneysByOrg: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("journeys after idempotent replay = %d, want 1 (no duplicate)", len(rows))
	}
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("plan items after idempotent replay = %d, want 1 (no duplicate insert)", len(items))
	}
}

func TestJourneysRest_Create_DifferentContentSameIdIsConflict(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()

	first := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID}))
	if first.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	second := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Different Name", "harvest", []string{apiaryID}))
	if second.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 (same id, different content), body = %s", second.Code, second.Body.String())
	}
}

func TestJourneysRest_Create_ValidationRejectsBadInput(t *testing.T) {
	f := newJourneysFixture(t)
	rec := f.do(t, http.MethodPost, "/v1/journeys", map[string]any{
		"id": "not-a-uuid", "name": "Journey", "main_activity_type": "harvest",
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (invalid id), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "id", "invalid") {
		t.Fatalf("problem errors = %+v, want id/invalid", p.Errors)
	}
}

// --- Read (GET, #46) ---

// TestJourneysRest_Get_Success proves the new GET /v1/journeys/{id} endpoint
// (#46, FR-JO-1) serves the same journeyDTO shape (apiary_ids included) the
// create/update handlers already return.
func TestJourneysRest_Get_Success(t *testing.T) {
	apiaryA, apiaryB := uuid.NewString(), uuid.NewString()
	f := newJourneysFixture(t, apiaryA, apiaryB)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Colheita", "harvest", []string{apiaryA, apiaryB})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodGet, "/v1/journeys/"+id, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got journeyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v, body = %s", err, rec.Body.String())
	}
	if got.ID != id || got.Name != "Colheita" || got.MainActivityType != "harvest" || got.Status != "open" {
		t.Fatalf("got journey = %+v, want id=%s name=Colheita status=open type=harvest", got, id)
	}
	if len(got.ApiaryIDs) != 2 {
		t.Fatalf("apiary_ids = %v, want 2 entries", got.ApiaryIDs)
	}
}

func TestJourneysRest_Get_UnknownIdIsNotFound(t *testing.T) {
	f := newJourneysFixture(t)
	rec := f.do(t, http.MethodGet, "/v1/journeys/"+uuid.NewString(), nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown journey id, body = %s", rec.Code, rec.Body.String())
	}
}

// TestJourneysRest_Get_CrossOrgIsNotFound is the CRITICAL scope-hiding test
// this endpoint exists to satisfy (ADR-0002, mirroring apiaries' getApiary
// and the parallel PATCH/DELETE cross-org test above): a journey that
// belongs to a DIFFERENT organization must 404, indistinguishable from a
// nonexistent id — this is exactly the property activities' new
// JourneyVerifier depends on to answer "does this journey_id belong to the
// caller's org" without a dedicated internal endpoint.
func TestJourneysRest_Get_CrossOrgIsNotFound(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.doAs(t, otherOrgCaller(), http.MethodGet, "/v1/journeys/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-org get status = %d, want 404 (scope-hiding, ADR-0002), body = %s", rec.Code, rec.Body.String())
	}
}

// TestJourneysRest_Get_DeletedIsNotFound proves a tombstoned (soft-deleted)
// journey also 404s on GET — GetJourney's own query already filters
// `deleted_at IS NULL` (store/sqlc/queries/journeys.sql), this just proves
// the HTTP layer surfaces that as the expected 404 rather than leaking a
// deleted row.
func TestJourneysRest_Get_DeletedIsNotFound(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/journeys/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodGet, "/v1/journeys/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("get-after-delete status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

func TestJourneysRest_History_CreateProducesOneAuditRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID}))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: devseedOrg(), EntityType: "journey", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("audit rows = %d, want 1 (FR-HIS-1)", len(rows))
	}
	if rows[0].ChangeType != "create" {
		t.Fatalf("change_type = %q, want create", rows[0].ChangeType)
	}
	if uuidString(rows[0].ActorUserID) != devseed.UserID {
		t.Fatalf("audit actor_user_id = %q, want the creating user %q (FR-HIS-1: actor + timestamp)", uuidString(rows[0].ActorUserID), devseed.UserID)
	}
}

// --- PATCH /v1/journeys/{id} (FR-JO-4, D-21) ---

func updateBody(name, mainActivityType string, apiaryIDs []string, status *string) map[string]any {
	body := map[string]any{"name": name, "main_activity_type": mainActivityType, "apiary_ids": apiaryIDs}
	if status != nil {
		body["status"] = *status
	}
	return body
}

func TestJourneysRest_Update_Success(t *testing.T) {
	apiaryA, apiaryB := uuid.NewString(), uuid.NewString()
	f := newJourneysFixture(t, apiaryA, apiaryB)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryA})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+id, updateBody("Renamed Journey", "feeding", []string{apiaryB}, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got journeyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Name != "Renamed Journey" || got.MainActivityType != "feeding" || got.Status != "open" {
		t.Fatalf("updated journey = %+v, want name=Renamed Journey type=feeding status=open", got)
	}
	if len(got.ApiaryIDs) != 1 || got.ApiaryIDs[0] != apiaryB {
		t.Fatalf("updated apiary_ids = %v, want [%s]", got.ApiaryIDs, apiaryB)
	}
}

// TestJourneysRest_Update_Close is D-21's core AC: closing a journey moves it
// from open to closed via the same PATCH.
func TestJourneysRest_Update_Close(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	closed := "closed"
	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+id, updateBody("Journey", "harvest", []string{apiaryID}, &closed))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got journeyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != "closed" {
		t.Fatalf("status = %q, want closed (D-21)", got.Status)
	}
}

// TestJourneysRest_Update_UnaffectedPlanItemKeepsIdAndCreatedAt is the Go-side
// counterpart of journeys_repository_test.dart's "leaves an unaffected
// apiary's plan-item row untouched" test (code review parity gap, #45): a
// PATCH that keeps one apiary and adds another must not soft-delete-then-
// reinsert the unaffected apiary's plan-item row — its id/created_at must
// survive unchanged.
func TestJourneysRest_Update_UnaffectedPlanItemKeepsIdAndCreatedAt(t *testing.T) {
	apiaryA, apiaryB := uuid.NewString(), uuid.NewString()
	f := newJourneysFixture(t, apiaryA, apiaryB)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryA})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	before, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney (before): %v", err)
	}
	if len(before) != 1 || uuidString(before[0].ApiaryID) != apiaryA {
		t.Fatalf("plan items before update = %+v, want just %s", before, apiaryA)
	}

	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+id, updateBody("Journey", "harvest", []string{apiaryA, apiaryB}, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	after, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney (after): %v", err)
	}
	if len(after) != 2 {
		t.Fatalf("plan items after update = %+v, want 2 (apiaryA kept, apiaryB added)", after)
	}
	var kept *sqlcgen.JourneysJourneyPlanItem
	for i := range after {
		if uuidString(after[i].ApiaryID) == apiaryA {
			kept = &after[i]
		}
	}
	if kept == nil {
		t.Fatalf("plan items after update = %+v, want apiaryA still present", after)
	}
	if uuidString(kept.ID) != uuidString(before[0].ID) {
		t.Fatalf("apiaryA's plan-item id changed from %s to %s — an unaffected apiary must keep its row, not be soft-deleted-then-reinserted", uuidString(before[0].ID), uuidString(kept.ID))
	}
	if kept.CreatedAt.Time != before[0].CreatedAt.Time {
		t.Fatalf("apiaryA's plan-item created_at changed from %v to %v — an unaffected apiary's row must be untouched", before[0].CreatedAt.Time, kept.CreatedAt.Time)
	}
}

func TestJourneysRest_Update_RejectsUnknownStatus(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	bogus := "archived"
	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+id, updateBody("Journey", "harvest", []string{apiaryID}, &bogus))
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (unknown status), body = %s", rec.Code, rec.Body.String())
	}
}

func TestJourneysRest_Update_CrossOrgApiaryIdIsRejected(t *testing.T) {
	apiaryID := uuid.NewString()
	foreignApiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID) // foreignApiaryID deliberately NOT known
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+id, updateBody("Journey", "harvest", []string{apiaryID, foreignApiaryID}, nil))
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org apiary_id on edit must be rejected), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney: %v", err)
	}
	if len(items) != 1 || uuidString(items[0].ApiaryID) != apiaryID {
		t.Fatalf("plan items = %+v, want unchanged (just %s)", items, apiaryID)
	}
}

func TestJourneysRest_Update_UnknownIdIsNotFound(t *testing.T) {
	f := newJourneysFixture(t)
	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+uuid.NewString(), updateBody("Journey", "generic", nil, nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown journey id, body = %s", rec.Code, rec.Body.String())
	}
}

func TestJourneysRest_History_UpdateProducesAuditRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodPatch, "/v1/journeys/"+id, updateBody("Renamed", "harvest", []string{apiaryID}, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{OrganizationID: devseedOrg(), EntityType: "journey", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + update, FR-HIS-1)", len(rows))
	}
	if rows[1].ChangeType != "update" {
		t.Fatalf("second audit row change_type = %q, want update", rows[1].ChangeType)
	}
}

// --- DELETE /v1/journeys/{id} ---

func TestJourneysRest_Delete_Success(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodDelete, "/v1/journeys/"+id, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}}); err == nil {
		t.Fatalf("GetJourney found the deleted journey — deleted_at IS NULL filter must exclude it")
	}
}

func TestJourneysRest_Delete_UnknownIdIsNotFound(t *testing.T) {
	f := newJourneysFixture(t)
	rec := f.do(t, http.MethodDelete, "/v1/journeys/"+uuid.NewString(), nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown journey id, body = %s", rec.Code, rec.Body.String())
	}
}

func TestJourneysRest_Delete_AlreadyDeletedIsNotFound(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/journeys/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("first delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodDelete, "/v1/journeys/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("second delete status = %d, want 404 (already gone), body = %s", rec.Code, rec.Body.String())
	}
}

// TestJourneysRest_History_DeleteProducesAuditRow closes a coverage gap
// flagged by security review (#45): create/update REST paths each already had
// a dedicated audit-row test, but delete did not — FR-HIS-1 requires every
// create/edit/delete/close to be recorded (actor + timestamp), not just
// create/edit.
func TestJourneysRest_History_DeleteProducesAuditRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/journeys/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: devseedOrg(), EntityType: "journey", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + delete, FR-HIS-1)", len(rows))
	}
	if rows[1].ChangeType != "delete" {
		t.Fatalf("second audit row change_type = %q, want delete", rows[1].ChangeType)
	}
	if uuidString(rows[1].ActorUserID) != devseed.UserID {
		t.Fatalf("delete audit actor_user_id = %q, want the deleting user %q (FR-HIS-1: actor + timestamp)", uuidString(rows[1].ActorUserID), devseed.UserID)
	}
}

// TestJourneysRest_CrossOrg_WritesCannotTouchOtherOrgsRow is the REST-level
// IDOR regression guard (mirrors activities'
// TestActivitiesRest_CrossOrg_WritesCannotTouchOtherOrgsRow): org B must get
// 404 for PATCH/DELETE against a journey that actually belongs to org A, and
// org A's row must survive untouched.
func TestJourneysRest_CrossOrg_WritesCannotTouchOtherOrgsRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	other := otherOrgCaller()

	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(id, "Journey", "harvest", []string{apiaryID})); rec.Code != http.StatusCreated {
		t.Fatalf("org A create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recUpdate := f.doAs(t, other, http.MethodPatch, "/v1/journeys/"+id, updateBody("Hijacked", "generic", nil, nil))
	if recUpdate.Code != http.StatusNotFound {
		t.Fatalf("org B update status = %d, want 404 (scope-hiding, ADR-0002), body = %s", recUpdate.Code, recUpdate.Body.String())
	}
	recDelete := f.doAs(t, other, http.MethodDelete, "/v1/journeys/"+id, nil)
	if recDelete.Code != http.StatusNotFound {
		t.Fatalf("org B delete status = %d, want 404 (scope-hiding, ADR-0002), body = %s", recDelete.Code, recDelete.Body.String())
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetJourney for org A after cross-org attempts: %v (the row must survive untouched)", err)
	}
	if row.Name != "Journey" {
		t.Fatalf("org A journey = %+v, want unchanged (name=Journey)", row)
	}
}

// --- Store-layer cross-org isolation (FR-TEN-2) ---

func TestJourneysStore_GetJourney_CrossOrgReadReturnsNoRows(t *testing.T) {
	f := newJourneysFixture(t)
	ctx := context.Background()
	q := sqlcgen.New(f.pool)

	orgA, orgB, id := newUUID(t), newUUID(t), newUUID(t)
	now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
	if _, err := q.InsertJourney(ctx, sqlcgen.InsertJourneyParams{ID: id, OrganizationID: orgA, Name: "x", MainActivityType: "generic", Status: "open", UpdatedAt: now}); err != nil {
		t.Fatalf("InsertJourney: %v", err)
	}
	if _, err := q.GetJourney(ctx, sqlcgen.GetJourneyParams{OrganizationID: orgB, ID: id}); err == nil {
		t.Fatalf("GetJourney across orgs unexpectedly succeeded, want no rows")
	} else if err != pgx.ErrNoRows {
		t.Fatalf("GetJourney across orgs error = %v, want pgx.ErrNoRows", err)
	}
}

// --- /internal/sync validate/apply (FR-OF-1/Q-SYNC) ---

func journeyPutOp(id, name, mainActivityType string) map[string]any {
	return map[string]any{
		"op": "put", "entity_type": "journey", "id": id,
		"updated_at": "2026-07-16T10:00:00Z",
		"data":       map[string]any{"name": name, "main_activity_type": mainActivityType},
	}
}

func planItemPutOp(id, journeyID, apiaryID string) map[string]any {
	return map[string]any{
		"op": "put", "entity_type": "journey_plan_item", "id": id,
		"updated_at": "2026-07-16T10:00:00Z",
		"data":       map[string]any{"journey_id": journeyID, "apiary_id": apiaryID},
	}
}

func TestJourneysSync_ValidateThenApply_CreateWithPlanItems_Success(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	journeyID := uuid.NewString()
	planItemID := uuid.NewString()
	batch := map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "harvest"), planItemPutOp(planItemID, journeyID, apiaryID)}}

	if rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch); rec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Results []struct {
			Result string `json:"result"`
		} `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Results) != 2 {
		t.Fatalf("results = %+v, want 2 ops applied", got.Results)
	}
	for _, r := range got.Results {
		if r.Result != "applied" {
			t.Fatalf("results = %+v, want all applied", got.Results)
		}
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("GetJourney: %v", err)
	}
	if row.Status != "open" {
		t.Fatalf("status = %q, want open (default on materializing create)", row.Status)
	}
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney: %v", err)
	}
	if len(items) != 1 || uuidString(items[0].ApiaryID) != apiaryID {
		t.Fatalf("plan items = %+v, want one row for apiary %s", items, apiaryID)
	}
}

func TestJourneysSync_Validate_RejectsCrossOrgApiaryId(t *testing.T) {
	foreignApiaryID := uuid.NewString()
	f := newJourneysFixture(t) // no known apiary ids
	journeyID, planItemID := uuid.NewString(), uuid.NewString()
	batch := map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "harvest"), planItemPutOp(planItemID, journeyID, foreignApiaryID)}}

	rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org/unknown apiary_id), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "ops[1].data.apiary_id", "not_found") {
		t.Fatalf("problem errors = %+v, want ops[1].data.apiary_id/not_found", p.Errors)
	}
}

func TestJourneysSync_Apply_CrossOrgApiaryIdIsNoOp(t *testing.T) {
	foreignApiaryID := uuid.NewString()
	f := newJourneysFixture(t) // no known apiary ids
	journeyID, planItemID := uuid.NewString(), uuid.NewString()
	batch := map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "harvest"), planItemPutOp(planItemID, journeyID, foreignApiaryID)}}

	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200 (unknown/foreign apiary_id is a no-op, not an error), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("plan items = %+v, want none (cross-org apiary_id must be a no-op)", items)
	}
}

// TestJourneysSync_Apply_CrossOrgJourneyIdIsNoOp is the journey_id-side
// counterpart of TestJourneysSync_Apply_CrossOrgApiaryIdIsNoOp, added per
// security review (#45): this exact bug class — a cross-tenant IDOR on a
// sync-apply write — is called out in this repo's own history as a
// recurring CRITICAL-severity finding (e.g. the counter-sync incident), so
// it gets its own dedicated regression rather than relying on inspection
// alone. Org B pushes a journey_plan_item put whose journey_id belongs to
// org A (created via REST, never shared with org B by any legitimate
// means) — applyJourneyPlanItemOp's org-scoped GetJourneyForUpdate read
// (sync.go) must treat the foreign journey_id as not-found and silently
// no-op, never attach org B's op to org A's journey or leak its existence.
func TestJourneysSync_Apply_CrossOrgJourneyIdIsNoOp(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	other := otherOrgCaller()

	orgAJourneyID := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/journeys", createBody(orgAJourneyID, "Journey", "harvest", nil)); rec.Code != http.StatusCreated {
		t.Fatalf("org A create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	planItemID := uuid.NewString()
	batch := map[string]any{"ops": []any{planItemPutOp(planItemID, orgAJourneyID, apiaryID)}}
	rec := f.doAs(t, other, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200 (cross-org journey_id must be a silent no-op, not an error), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(orgAJourneyID), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney (org A): %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("org A plan items = %+v, want none (org B's op must never attach to org A's journey)", items)
	}

	var count int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM journeys.journey_plan_items WHERE id = $1", pgtype.UUID{Bytes: uuid.MustParse(planItemID), Valid: true}).Scan(&count); err != nil {
		t.Fatalf("query journey_plan_items by id: %v", err)
	}
	if count != 0 {
		t.Fatalf("journey_plan_items row for id %s = %d rows, want 0 (must never be inserted under any organization_id)", planItemID, count)
	}
}

func TestJourneysSync_Apply_DedupesApiaryOwnershipCalls(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	journeyID := uuid.NewString()
	batch := map[string]any{"ops": []any{
		journeyPutOp(journeyID, "Journey", "harvest"),
		planItemPutOp(uuid.NewString(), journeyID, apiaryID),
		planItemPutOp(uuid.NewString(), journeyID, apiaryID),
	}}
	// Both plan items target the SAME apiary — invalid content (duplicate),
	// but that's a validation concern for the REST path only; the sync path
	// has no such duplicate guard at the op level (each op is independent),
	// so the second put simply finds the apiary already on the plan via a
	// different row id and is a benign no-op. What this test actually
	// verifies is the ownership-call de-dup itself.
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if got := f.apiaries.hitCount(apiaryID); got != 1 {
		t.Fatalf("apiaries ownership calls for apiary %s = %d, want exactly 1 (batch must de-dup ownership checks)", apiaryID, got)
	}
}

func TestJourneysSync_Apply_PlanItemAlreadyOnPlanViaDifferentIdIsNoOp(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	journeyID := uuid.NewString()
	first := map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "harvest"), planItemPutOp(uuid.NewString(), journeyID, apiaryID)}}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", first); rec.Code != http.StatusOK {
		t.Fatalf("first apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	// A second device adds the SAME apiary offline, generating a DIFFERENT
	// local row id for what the server must treat as the same plan fact.
	second := map[string]any{"ops": []any{planItemPutOp(uuid.NewString(), journeyID, apiaryID)}}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", second)
	if rec.Code != http.StatusOK {
		t.Fatalf("second apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("plan items = %d, want 1 (the SET already held this apiary, no duplicate row)", len(items))
	}
}

func TestJourneysSync_Apply_Delete_PlanItemRemovesFromPlan(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newJourneysFixture(t, apiaryID)
	journeyID, planItemID := uuid.NewString(), uuid.NewString()
	create := map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "harvest"), planItemPutOp(planItemID, journeyID, apiaryID)}}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", create); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	deleteOp := map[string]any{"op": "delete", "entity_type": "journey_plan_item", "id": planItemID, "updated_at": "2026-07-16T11:00:00Z"}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	items, err := q.ListJourneyPlanItemsByJourney(context.Background(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: devseedOrg(), JourneyID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("ListJourneyPlanItemsByJourney: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("plan items = %+v, want none after removal", items)
	}

	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{OrganizationID: devseedOrg(), EntityType: "journey", EntityID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	// 3 rows: the journey's own create, the plan-item PUT that added apiaryID
	// (folded into a journey "update" row), and the plan-item DELETE that
	// removed it (also folded in) — every add/remove of the plan is
	// individually recorded (FR-HIS-1), even though it arrived as its own
	// sync op rather than a single REST PATCH.
	if len(rows) != 3 {
		t.Fatalf("audit rows = %d, want 3 (create + plan-item add + plan-item removal, FR-HIS-1)", len(rows))
	}
	if rows[2].ChangeType != "update" {
		t.Fatalf("third audit row change_type = %q, want update", rows[2].ChangeType)
	}
}

func TestJourneysSync_Apply_Delete_MissingPlanItemIsNoOp(t *testing.T) {
	f := newJourneysFixture(t)
	deleteOp := map[string]any{"op": "delete", "entity_type": "journey_plan_item", "id": uuid.NewString(), "updated_at": "2026-07-16T11:00:00Z"}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (deleting an id the server never had is a no-op), body = %s", rec.Code, rec.Body.String())
	}
}

func TestJourneysSync_Apply_IdempotentReplayOfJourneyCreate(t *testing.T) {
	f := newJourneysFixture(t)
	journeyID := uuid.NewString()
	batch := map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "generic")}}

	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch); rec.Code != http.StatusOK {
		t.Fatalf("first apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch); rec.Code != http.StatusOK {
		t.Fatalf("replayed apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListJourneysByOrg(context.Background(), sqlcgen.ListJourneysByOrgParams{OrganizationID: devseedOrg(), Limit: 50})
	if err != nil {
		t.Fatalf("ListJourneysByOrg: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("journeys after idempotent replay = %d, want 1 (no duplicate)", len(rows))
	}
}

func TestJourneysSync_Apply_Patch_UpdatesJourney(t *testing.T) {
	f := newJourneysFixture(t)
	journeyID := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "generic")}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	patchOp := map[string]any{
		"op": "patch", "entity_type": "journey", "id": journeyID,
		"updated_at": "2026-07-16T11:00:00Z", // strictly newer than the create's 10:00:00Z
		"data":       map[string]any{"name": "Renamed", "main_activity_type": "harvest", "status": "closed"},
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{patchOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("GetJourney: %v", err)
	}
	if row.Name != "Renamed" || row.MainActivityType != "harvest" || row.Status != "closed" {
		t.Fatalf("row after patch = %+v, want name=Renamed type=harvest status=closed", row)
	}
}

// TestJourneysSync_Apply_OlderPatchIsSuperseded is the LWW safety-net test:
// a stale offline edit must not clobber a newer one, and the loss must be
// logged (sync.md §4.1/§4.2), not silently dropped.
func TestJourneysSync_Apply_OlderPatchIsSuperseded(t *testing.T) {
	f := newJourneysFixture(t)
	journeyID := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "generic")}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	newerPatch := map[string]any{
		"op": "patch", "entity_type": "journey", "id": journeyID,
		"updated_at": "2026-07-16T11:00:00Z",
		"data":       map[string]any{"name": "Newer Name", "main_activity_type": "generic"},
	}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{newerPatch}}); rec.Code != http.StatusOK {
		t.Fatalf("newer patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	stalePatch := map[string]any{
		"op": "patch", "entity_type": "journey", "id": journeyID,
		"updated_at": "2026-07-16T10:30:00Z", // between create (10:00) and the newer patch (11:00)
		"data":       map[string]any{"name": "Stale Name", "main_activity_type": "generic"},
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{stalePatch}})
	if rec.Code != http.StatusOK {
		t.Fatalf("stale patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Results []struct {
			Result string `json:"result"`
		} `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Results) != 1 || got.Results[0].Result != "superseded" {
		t.Fatalf("stale patch result = %+v, want one superseded op (LWW: the newer edit must win)", got.Results)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("GetJourney: %v (the row must have survived — the stale patch lost the LWW compare)", err)
	}
	if row.Name != "Newer Name" {
		t.Fatalf("surviving row name = %q, want %q (the newer edit's content, not clobbered by the stale patch)", row.Name, "Newer Name")
	}

	conflicts, err := f.pool.Query(context.Background(), "SELECT count(*) FROM journeys.sync_conflict_log WHERE organization_id = $1 AND entity_id = $2", devseedOrg(), pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true})
	if err != nil {
		t.Fatalf("query sync_conflict_log: %v", err)
	}
	defer conflicts.Close()
	var count int
	for conflicts.Next() {
		if err := conflicts.Scan(&count); err != nil {
			t.Fatalf("scan conflict count: %v", err)
		}
	}
	if count != 1 {
		t.Fatalf("sync_conflict_log rows = %d, want 1 (LWW losers are not lost, history.md §6)", count)
	}
}

func TestJourneysSync_Apply_Delete_TombstonesJourney(t *testing.T) {
	f := newJourneysFixture(t)
	journeyID := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{journeyPutOp(journeyID, "Journey", "generic")}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	deleteOp := map[string]any{"op": "delete", "entity_type": "journey", "id": journeyID, "updated_at": "2026-07-16T11:00:00Z"}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetJourney(context.Background(), sqlcgen.GetJourneyParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}}); err == nil {
		t.Fatalf("GetJourney found the tombstoned row — deleted_at IS NULL filter must exclude it")
	}
	row, err := q.GetJourneyForUpdate(context.Background(), sqlcgen.GetJourneyForUpdateParams{OrganizationID: devseedOrg(), ID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true}})
	if err != nil {
		t.Fatalf("GetJourneyForUpdate: %v (soft-deleted row must still physically exist)", err)
	}
	if !row.DeletedAt.Valid {
		t.Fatalf("deleted_at not set — expected a tombstone, not a hard delete")
	}

	// FR-HIS-1 (security-review coverage gap, #45): a delete arriving via
	// sync-apply, same as one arriving via REST, must still be recorded.
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: devseedOrg(), EntityType: "journey", EntityID: pgtype.UUID{Bytes: uuid.MustParse(journeyID), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + delete, FR-HIS-1)", len(rows))
	}
	if rows[1].ChangeType != "delete" {
		t.Fatalf("second audit row change_type = %q, want delete", rows[1].ChangeType)
	}
}
