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
		ctx := authn.ContextWithClaims(r.Context(), claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type activitiesFixture struct {
	srv  *servicetemplate.Server
	pool *pgxpool.Pool
}

func newActivitiesFixture(t *testing.T) *activitiesFixture {
	t.Helper()
	ctx := context.Background()
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

	return &activitiesFixture{srv: srv, pool: pool}
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
