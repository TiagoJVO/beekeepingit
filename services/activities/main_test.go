// Package main — integration tests for #38: the migrated schema shape
// (tenancy: every owned table carries organization_id, FR-TEN-2), the
// store-layer insert/read round trip and its cross-org isolation, and the
// /internal/activities/validate HTTP endpoint. Uses a real, containerized
// Postgres (testcontainers), mirroring services/apiaries/main_test.go and
// services/organizations/main_test.go's own fixture conventions — plain
// postgres:16-alpine (this service has no PostGIS columns, unlike apiaries).
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

	"github.com/TiagoJVO/beekeepingit/services/activities/api"
	"github.com/TiagoJVO/beekeepingit/services/activities/store"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/activities/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

// testOrgHeader lets a test request stand in as a caller resolved to a
// different org/user/role than the devseed default — mirrors
// apiaries/main_test.go's identical helper, the only way these in-process
// tests can exercise a cross-organization apiary_id attempt without a live
// identity/organizations pair to resolve against.
const testOrgHeader = "X-Test-Org-Claims"

// injectClaims stands in for the authn + org-resolver chain, mirroring
// apiaries/main_test.go's helper of the same name: these tests exercise the
// route handler directly with a known org/user rather than standing up a
// live identity/organizations pair. The shared authn package has its own
// unit tests for the real middleware chain (NewMiddleware/NewOrgResolver);
// wiring it into main.go (scoped := authnMW(orgMW(roleMW(...)))) is the
// structural proof this service uses it, same as every other domain
// service.
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

type activitiesFixture struct {
	srv      *servicetemplate.Server
	pool     *pgxpool.Pool
	apiaries *fakeApiaries
}

// fakeApiaries stands in for the real apiaries service's GET /v1/apiaries/{id}
// (api/apiaries_client.go's ApiaryVerifier target): 200 for any id in
// `known`, 404 otherwise — enough to exercise the CRITICAL cross-org
// apiary_id tenancy guard (#39's carry-over from #38's review, mirroring
// #284's cross-tenant IDOR fix) without standing up a second real service +
// database in this test binary. It also **counts per-id hits** so a test can
// prove the batch write path de-duplicates its ownership calls (one upstream
// call per distinct apiary, not one per op — the HIGH/MEDIUM review fix).
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

func (f *fakeApiaries) totalHits() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.hits {
		n += c
	}
	return n
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

// newActivitiesFixture builds the test fixture. knownApiaryIDs (variadic —
// most tests below don't create anything and need none) seeds the fake
// apiaries server's known set; a REST-create/sync-apply test that expects a
// SUCCESSFUL write must pass its apiary_id here, otherwise the (correct)
// tenancy guard rejects it, exactly as it must for a real foreign id.
func newActivitiesFixture(t *testing.T, knownApiaryIDs ...string) *activitiesFixture {
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
	createSchema(ctx, t, dbCfg, "activities")
	// SearchPath matches infra/helm's DB_SEARCH_PATH=activities (schema-per-
	// service, D-6), same convention as apiaries/organizations.
	dbCfg.SearchPath = "activities"
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	cfg := config.Config{ServiceName: "activities-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })
	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/internal/activities", injectClaims(api.InternalValidateRouter()))
	srv.Mount("/v1/activities", injectClaims(api.Router(pool, verifier)))
	srv.Mount("/internal/sync", injectClaims(api.InternalSyncRouter(pool, verifier)))

	return &activitiesFixture{srv: srv, pool: pool, apiaries: fakeApiaries}
}

func (f *activitiesFixture) do(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
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
	f.srv.Router().ServeHTTP(rec, req)
	return rec
}

// createSchema provisions the service's schema before migrating, standing in
// for infra's postgres chart bootstrap (mirrors apiaries/organizations).
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

// --- Tenancy schema check (FR-TEN-2, mirrors apiaries'
// TestApiariesSchema_EveryOwnedTableCarriesOrganizationID) ---

func TestActivitiesSchema_EveryOwnedTableCarriesOrganizationID(t *testing.T) {
	f := newActivitiesFixture(t)
	unscoped, err := dbaccess.UnscopedTables(context.Background(), f.pool, "activities")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(unscoped) != 0 {
		t.Fatalf("tables missing organization_id = %v, want none (every owned table must carry organization_id, FR-TEN-2)", unscoped)
	}
}

// --- /internal/activities/validate HTTP surface ---

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

func TestActivitiesService_Validate_AcceptsAValidHarvest(t *testing.T) {
	f := newActivitiesFixture(t)
	body := map[string]any{
		"type":        api.TypeHarvest,
		"occurred_at": "2026-07-16",
		"attributes":  map[string]any{"honey_supers": 4, "honey_kg": 12.5, "hives_involved": 6},
	}
	rec := f.do(t, http.MethodPost, "/internal/activities/validate", body)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Valid bool `json:"valid"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !got.Valid {
		t.Fatalf("valid = false, want true")
	}
}

func TestActivitiesService_Validate_RejectsMissingRequiredHoneySupers(t *testing.T) {
	f := newActivitiesFixture(t)
	body := map[string]any{
		"type":        api.TypeHarvest,
		"occurred_at": "2026-07-16",
		"attributes":  map[string]any{"honey_kg": 12.5},
	}
	rec := f.do(t, http.MethodPost, "/internal/activities/validate", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (missing required honey_supers), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "attributes.honey_supers", "required") {
		t.Fatalf("problem errors = %+v, want attributes.honey_supers/required", p.Errors)
	}
}

func TestActivitiesService_Validate_RejectsUnknownAttribute(t *testing.T) {
	f := newActivitiesFixture(t)
	body := map[string]any{
		"type":        api.TypeGeneric,
		"occurred_at": "2026-07-16",
		"attributes":  map[string]any{"unexpected_field": "x"},
	}
	rec := f.do(t, http.MethodPost, "/internal/activities/validate", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (unknown attribute), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "attributes.unexpected_field", "invalid") {
		t.Fatalf("problem errors = %+v, want attributes.unexpected_field/invalid", p.Errors)
	}
}

func TestActivitiesService_Validate_RejectsUnknownType(t *testing.T) {
	f := newActivitiesFixture(t)
	body := map[string]any{"type": "nucs", "occurred_at": "2026-07-16"}
	rec := f.do(t, http.MethodPost, "/internal/activities/validate", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (unknown type), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "type", "invalid") {
		t.Fatalf("problem errors = %+v, want type/invalid", p.Errors)
	}
}

func TestActivitiesService_Validate_RejectsFeedTypeOutsideVocabulary(t *testing.T) {
	f := newActivitiesFixture(t)
	body := map[string]any{
		"type":        api.TypeFeeding,
		"occurred_at": "2026-07-16",
		"attributes":  map[string]any{"feed_type": "Sugar Water", "feed_amount": 1},
	}
	rec := f.do(t, http.MethodPost, "/internal/activities/validate", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (feed_type outside candidate vocabulary), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "attributes.feed_type", "invalid") {
		t.Fatalf("problem errors = %+v, want attributes.feed_type/invalid", p.Errors)
	}
}

func TestActivitiesService_Validate_RejectsMalformedBody(t *testing.T) {
	f := newActivitiesFixture(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/internal/activities/validate", strings.NewReader("not json"))
	f.srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (malformed JSON body), body = %s", rec.Code, rec.Body.String())
	}
}

// --- Store-layer insert/read + cross-org isolation (FR-TEN-2) ---

func newUUID(t *testing.T) pgtype.UUID {
	t.Helper()
	return pgtype.UUID{Bytes: uuid.New(), Valid: true}
}

// uuidString reads a stored pgtype.UUID column back as its string form —
// this test file's own copy of api's unexported helper of the same name
// (can't import an unexported identifier across packages).
func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

func TestActivitiesStore_InsertAndGet_RoundTrip(t *testing.T) {
	f := newActivitiesFixture(t)
	ctx := context.Background()
	q := sqlcgen.New(f.pool)

	org := newUUID(t)
	apiaryID := newUUID(t)
	performedBy := newUUID(t)
	id := newUUID(t)
	occurredAt := pgtype.Date{Time: time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC), Valid: true}
	attrs := []byte(`{"honey_supers": 3, "honey_kg": 9.5}`)

	row, err := q.InsertActivity(ctx, sqlcgen.InsertActivityParams{
		ID: id, OrganizationID: org, ApiaryID: apiaryID, PerformedBy: performedBy,
		Type: api.TypeHarvest, OccurredAt: occurredAt, Attributes: attrs,
		UpdatedAt: pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
	})
	if err != nil {
		t.Fatalf("InsertActivity: %v", err)
	}
	if row.Type != api.TypeHarvest {
		t.Fatalf("inserted type = %q, want %q", row.Type, api.TypeHarvest)
	}
	if row.OrganizationID != org {
		t.Fatalf("inserted organization_id mismatch")
	}

	got, err := q.GetActivity(ctx, sqlcgen.GetActivityParams{OrganizationID: org, ID: id})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if got.ApiaryID != apiaryID || got.PerformedBy != performedBy {
		t.Fatalf("GetActivity row = %+v, want apiary_id=%v performed_by=%v", got, apiaryID, performedBy)
	}
}

func TestActivitiesStore_GetActivity_CrossOrgReadReturnsNoRows(t *testing.T) {
	f := newActivitiesFixture(t)
	ctx := context.Background()
	q := sqlcgen.New(f.pool)

	orgA := newUUID(t)
	orgB := newUUID(t)
	id := newUUID(t)
	occurredAt := pgtype.Date{Time: time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC), Valid: true}

	if _, err := q.InsertActivity(ctx, sqlcgen.InsertActivityParams{
		ID: id, OrganizationID: orgA, ApiaryID: newUUID(t), PerformedBy: newUUID(t),
		Type: api.TypeGeneric, OccurredAt: occurredAt, Attributes: []byte(`{}`),
		UpdatedAt: pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
	}); err != nil {
		t.Fatalf("InsertActivity: %v", err)
	}

	// Org B looks up org A's activity id — must find nothing (FR-TEN-2:
	// every query is org-scoped; a foreign org can't read another org's
	// row even by guessing/knowing its id).
	if _, err := q.GetActivity(ctx, sqlcgen.GetActivityParams{OrganizationID: orgB, ID: id}); err == nil {
		t.Fatalf("GetActivity across orgs unexpectedly succeeded, want no rows")
	} else if err != pgx.ErrNoRows {
		t.Fatalf("GetActivity across orgs error = %v, want pgx.ErrNoRows", err)
	}
}

func TestActivitiesStore_ListActivitiesByOrg_CrossOrgIsolation(t *testing.T) {
	f := newActivitiesFixture(t)
	ctx := context.Background()
	q := sqlcgen.New(f.pool)

	orgA := newUUID(t)
	orgB := newUUID(t)
	occurredAt := pgtype.Date{Time: time.Date(2026, 7, 16, 0, 0, 0, 0, time.UTC), Valid: true}
	now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}

	for i := 0; i < 2; i++ {
		if _, err := q.InsertActivity(ctx, sqlcgen.InsertActivityParams{
			ID: newUUID(t), OrganizationID: orgA, ApiaryID: newUUID(t), PerformedBy: newUUID(t),
			Type: api.TypeGeneric, OccurredAt: occurredAt, Attributes: []byte(`{}`), UpdatedAt: now,
		}); err != nil {
			t.Fatalf("InsertActivity org A: %v", err)
		}
	}
	if _, err := q.InsertActivity(ctx, sqlcgen.InsertActivityParams{
		ID: newUUID(t), OrganizationID: orgB, ApiaryID: newUUID(t), PerformedBy: newUUID(t),
		Type: api.TypeGeneric, OccurredAt: occurredAt, Attributes: []byte(`{}`), UpdatedAt: now,
	}); err != nil {
		t.Fatalf("InsertActivity org B: %v", err)
	}

	rows, err := q.ListActivitiesByOrg(ctx, sqlcgen.ListActivitiesByOrgParams{OrganizationID: orgA, Limit: 50})
	if err != nil {
		t.Fatalf("ListActivitiesByOrg: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("org A activities = %d, want 2 (org B's row must not leak)", len(rows))
	}
	for _, r := range rows {
		if r.OrganizationID != orgA {
			t.Fatalf("row organization_id = %v, want %v (cross-org leak)", r.OrganizationID, orgA)
		}
	}
}

// --- Migration/table shape (DB-level constraints, defense in depth) ---

func TestActivitiesMigration_OrganizationIDNotNull(t *testing.T) {
	f := newActivitiesFixture(t)
	_, err := f.pool.Exec(context.Background(), `
		INSERT INTO activities.activities (id, apiary_id, performed_by, type, occurred_at, updated_at)
		VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'generic', '2026-07-16', now())`)
	if err == nil {
		t.Fatalf("insert with NULL organization_id unexpectedly succeeded — NOT NULL constraint not enforced at the DB level (FR-TEN-2)")
	}
}

func TestActivitiesMigration_ThreeTablesCreated(t *testing.T) {
	f := newActivitiesFixture(t)
	for _, table := range []string{"activities", "audit_log", "sync_conflict_log"} {
		var exists bool
		err := f.pool.QueryRow(context.Background(), `
			SELECT EXISTS (
				SELECT 1 FROM information_schema.tables
				WHERE table_schema = 'activities' AND table_name = $1
			)`, table).Scan(&exists)
		if err != nil {
			t.Fatalf("query information_schema.tables for %s: %v", table, err)
		}
		if !exists {
			t.Fatalf("activities.%s table does not exist", table)
		}
	}
}

// --- POST /v1/activities (#39, FR-AC-2) ---

func validHarvestBody(id, apiaryID string) map[string]any {
	return map[string]any{
		"id":          id,
		"apiary_id":   apiaryID,
		"type":        api.TypeHarvest,
		"occurred_at": "2026-07-16",
		"attributes":  map[string]any{"honey_supers": 4, "honey_kg": 12.5},
	}
}

func TestActivitiesRest_Create_Success(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		ID          string         `json:"id"`
		ApiaryID    string         `json:"apiary_id"`
		PerformedBy string         `json:"performed_by"`
		Type        string         `json:"type"`
		OccurredAt  string         `json:"occurred_at"`
		Attributes  map[string]any `json:"attributes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v, body = %s", err, rec.Body.String())
	}
	if got.ID != id || got.ApiaryID != apiaryID || got.Type != api.TypeHarvest || got.OccurredAt != "2026-07-16" {
		t.Fatalf("created activity = %+v, want id=%s apiary_id=%s type=%s occurred_at=2026-07-16", got, id, apiaryID, api.TypeHarvest)
	}
	if got.Attributes["honey_supers"] != float64(4) {
		t.Fatalf("attributes.honey_supers = %v, want 4", got.Attributes["honey_supers"])
	}
}

// TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected is the CRITICAL test
// this PR exists to add (carry-over from #38's review, mirroring #284's
// "fix(apiaries): close cross-tenant IDOR on counter sync"): an apiary_id
// that exists but belongs to a DIFFERENT organization than the caller's
// resolved org must never be accepted — the create must be rejected before
// any row is written, and no activity or audit row must be left behind.
func TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected(t *testing.T) {
	foreignApiaryID := uuid.NewString()
	// The fake apiaries server is org-agnostic (mirrors the real GET
	// /v1/apiaries/{id}'s scope-hiding: apiaries itself is what enforces
	// "this id belongs to org X", not this test double) — the point being
	// tested here is that activities' OWN write path still must call it and
	// honor a rejection for an id the CALLER does not have access to. Model
	// that by NOT registering foreignApiaryID as known at all: from this
	// service's perspective, "belongs to another org" and "doesn't exist"
	// are the same 404 (ADR-0002 scope-hiding) — either way, the write must
	// be rejected.
	f := newActivitiesFixture(t) // no known apiary ids at all
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, foreignApiaryID))
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org/unknown apiary_id must be rejected), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "apiary_id", "not_found") {
		t.Fatalf("problem errors = %+v, want apiary_id/not_found", p.Errors)
	}

	// Nothing must have been written — the tenancy guard runs BEFORE the
	// insert (write.go's createActivity), so a rejected cross-org create
	// leaves no row and no audit trail at all.
	q := sqlcgen.New(f.pool)
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetActivity found a row after a rejected cross-org create — the write must not have happened")
	}
}

// TestActivitiesRest_Create_AttributionIsFromClaims_NeverClientSupplied
// (FR-TEN-2): performed_by is derived server-side from the caller's
// resolved user id (requireOrg → authn.FromContext), never from any
// client-supplied field — the request body has no performed_by field at
// all (activityCreateRequest's doc comment), so this proves the stored
// value is the devseed caller's own id regardless of what else is in play.
func TestActivitiesRest_Create_AttributionIsFromClaims_NeverClientSupplied(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		PerformedBy string `json:"performed_by"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.PerformedBy != devseed.UserID {
		t.Fatalf("performed_by = %q, want the resolved caller's own id %q", got.PerformedBy, devseed.UserID)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if uuidString(row.PerformedBy) != devseed.UserID {
		t.Fatalf("stored performed_by = %q, want %q", uuidString(row.PerformedBy), devseed.UserID)
	}
}

func TestActivitiesRest_Create_IdempotentReplayDoesNotDuplicate(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	body := validHarvestBody(id, apiaryID)

	first := f.do(t, http.MethodPost, "/v1/activities", body)
	if first.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	second := f.do(t, http.MethodPost, "/v1/activities", body)
	if second.Code != http.StatusCreated {
		t.Fatalf("replayed create status = %d, want 201 (idempotent replay), body = %s", second.Code, second.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListActivitiesByOrg(context.Background(), sqlcgen.ListActivitiesByOrgParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}, Limit: 50,
	})
	if err != nil {
		t.Fatalf("ListActivitiesByOrg: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("activities after idempotent replay = %d, want 1 (no duplicate)", len(rows))
	}
}

func TestActivitiesRest_Create_DifferentContentSameIdIsConflict(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()

	first := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID))
	if first.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	changed := validHarvestBody(id, apiaryID)
	changed["attributes"] = map[string]any{"honey_supers": 9}
	second := f.do(t, http.MethodPost, "/v1/activities", changed)
	if second.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 (same id, different content), body = %s", second.Code, second.Body.String())
	}
}

func TestActivitiesRest_Create_ValidationRejectsBadInput(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)

	rec := f.do(t, http.MethodPost, "/v1/activities", map[string]any{
		"id": "not-a-uuid", "apiary_id": apiaryID, "type": api.TypeGeneric, "occurred_at": "2026-07-16",
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (invalid id), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "id", "invalid") {
		t.Fatalf("problem errors = %+v, want id/invalid", p.Errors)
	}
}

func TestActivitiesRest_History_CreateProducesOneAuditRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "activity",
		EntityID:       pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
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

// --- /internal/sync validate/apply (#39, FR-OF-1/Q-SYNC — offline create) ---

func syncOp(id, apiaryID string) map[string]any {
	return map[string]any{
		"op":          "put",
		"entity_type": "activity",
		"id":          id,
		"updated_at":  "2026-07-16T10:00:00Z",
		"data": map[string]any{
			"apiary_id":   apiaryID,
			"type":        api.TypeGeneric,
			"occurred_at": "2026-07-16",
			"attributes":  map[string]any{"notes": "queued offline"},
		},
	}
}

func TestActivitiesSync_ValidateThenApply_CreateActivity_Success(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOp(id, apiaryID)}}

	validateRec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if validateRec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", validateRec.Code, validateRec.Body.String())
	}

	applyRec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if applyRec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", applyRec.Code, applyRec.Body.String())
	}
	var got struct {
		Results []struct {
			ID     string `json:"id"`
			Result string `json:"result"`
		} `json:"results"`
	}
	if err := json.Unmarshal(applyRec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode apply response: %v", err)
	}
	if len(got.Results) != 1 || got.Results[0].Result != "applied" {
		t.Fatalf("apply results = %+v, want one applied op", got.Results)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	// Offline create attribution (FR-TEN-2) must survive the sync path too —
	// performed_by is resolved server-side from the sync-apply caller's own
	// claims, same as the REST path, never from the queued op's payload
	// (which carries no performed_by field at all).
	if uuidString(row.PerformedBy) != devseed.UserID {
		t.Fatalf("performed_by after sync apply = %q, want %q", uuidString(row.PerformedBy), devseed.UserID)
	}
}

// TestActivitiesSync_Validate_RejectsCrossOrgApiaryId is the sync-path
// counterpart of TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected — the
// offline queue must not be able to bypass the same tenancy guard the
// online REST path enforces.
func TestActivitiesSync_Validate_RejectsCrossOrgApiaryId(t *testing.T) {
	foreignApiaryID := uuid.NewString()
	f := newActivitiesFixture(t) // no known apiary ids
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOp(id, foreignApiaryID)}}

	rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org/unknown apiary_id), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "ops[0].data.apiary_id", "not_found") {
		t.Fatalf("problem errors = %+v, want ops[0].data.apiary_id/not_found", p.Errors)
	}
}

// TestActivitiesSync_Apply_CrossOrgApiaryIdIsNoOp proves the apply endpoint
// re-checks ownership independently of validate (zero-trust, sync.md §6.2 —
// apply is a separate request) rather than trusting that validate already
// ran for this exact op, and that a rejected op writes nothing.
func TestActivitiesSync_Apply_CrossOrgApiaryIdIsNoOp(t *testing.T) {
	foreignApiaryID := uuid.NewString()
	f := newActivitiesFixture(t) // no known apiary ids
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOp(id, foreignApiaryID)}}

	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200 (unknown/foreign apiary_id is a no-op, not an error), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetActivity found a row for a cross-org apiary_id op — it must have been a no-op")
	}
}

func TestActivitiesSync_Apply_IdempotentReplayDoesNotDuplicate(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOp(id, apiaryID)}}

	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch); rec.Code != http.StatusOK {
		t.Fatalf("first apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch); rec.Code != http.StatusOK {
		t.Fatalf("replayed apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListActivitiesByOrg(context.Background(), sqlcgen.ListActivitiesByOrgParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}, Limit: 50,
	})
	if err != nil {
		t.Fatalf("ListActivitiesByOrg: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("activities after idempotent replay = %d, want 1 (no duplicate)", len(rows))
	}
}

// TestActivitiesSync_Apply_DedupesApiaryOwnershipCalls is the regression
// guard for the HIGH/MEDIUM review finding: the per-op cross-service
// ownership call must be resolved ONCE per distinct apiary_id, up front
// (resolveApiaryOwnership), NOT once per op inside the DB transaction. A
// batch of three ops all against the SAME apiary must therefore hit the
// (fake) apiaries service exactly ONCE — proving both the de-duplication and
// that no ownership HTTP call is made per-op inside the transaction.
func TestActivitiesSync_Apply_DedupesApiaryOwnershipCalls(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	batch := map[string]any{"ops": []any{
		syncOp(uuid.NewString(), apiaryID),
		syncOp(uuid.NewString(), apiaryID),
		syncOp(uuid.NewString(), apiaryID),
	}}

	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	if got := f.apiaries.hitCount(apiaryID); got != 1 {
		t.Fatalf("apiaries ownership calls for apiary %s = %d, want exactly 1 (batch must de-dup ownership checks, one call per distinct apiary, not per op)", apiaryID, got)
	}
	// All three ops must still have been applied.
	q := sqlcgen.New(f.pool)
	rows, err := q.ListActivitiesByOrg(context.Background(), sqlcgen.ListActivitiesByOrgParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}, Limit: 50,
	})
	if err != nil {
		t.Fatalf("ListActivitiesByOrg: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("activities created = %d, want 3 (all ops applied despite the single ownership call)", len(rows))
	}
}

// TestActivitiesSync_Validate_DedupesApiaryOwnershipCalls is the validate-path
// counterpart of the de-dup regression guard above: validate also fans the
// ownership check out once per distinct apiary_id, not once per op.
func TestActivitiesSync_Validate_DedupesApiaryOwnershipCalls(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	batch := map[string]any{"ops": []any{
		syncOp(uuid.NewString(), apiaryID),
		syncOp(uuid.NewString(), apiaryID),
		syncOp(uuid.NewString(), apiaryID),
	}}

	rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if got := f.apiaries.hitCount(apiaryID); got != 1 {
		t.Fatalf("apiaries ownership calls for apiary %s = %d, want exactly 1 (validate must de-dup too)", apiaryID, got)
	}
	if got := f.apiaries.totalHits(); got != 1 {
		t.Fatalf("total apiaries ownership calls = %d, want exactly 1", got)
	}
}
