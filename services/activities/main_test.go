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
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
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
	journeys *fakeJourneys
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
		// Mirrors the real handler's uuid.Parse(chi.URLParam(...)) (apiaries/
		// api/write.go) — case-insensitive, so this double doesn't fail a
		// non-canonically-cased id the real service would accept.
		if parsed, err := uuid.Parse(id); err == nil {
			id = parsed.String()
		}
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

// fakeJourneys is fakeApiaries' #46 counterpart, standing in for the real
// journeys service's GET /v1/journeys/{id} (api/journeys_client.go's
// JourneyVerifier target): 200 for any id in `known`, 404 otherwise — enough
// to exercise the CRITICAL cross-org journey_id tenancy guard without
// standing up a second real service + database in this test binary. Also
// counts per-id hits so a test can prove the sync batch path de-duplicates
// its ownership calls, mirroring fakeApiaries.
type fakeJourneys struct {
	server *httptest.Server
	mu     sync.Mutex
	hits   map[string]int
}

func (f *fakeJourneys) hitCount(journeyID string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[journeyID]
}

func newFakeJourneys(t *testing.T, known map[string]bool) *fakeJourneys {
	t.Helper()
	f := &fakeJourneys{hits: map[string]int{}}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/v1/journeys/")
		// Mirrors the real handler's uuid.Parse(chi.URLParam(...)), same
		// rationale as newFakeApiaries above.
		if parsed, err := uuid.Parse(id); err == nil {
			id = parsed.String()
		}
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
// tenancy guard rejects it, exactly as it must for a real foreign id. No
// journey_id is ever known by this variant — tests exercising journey_id
// ownership use newActivitiesFixtureWithJourneys instead.
func newActivitiesFixture(t *testing.T, knownApiaryIDs ...string) *activitiesFixture {
	t.Helper()
	return newActivitiesFixtureWithJourneys(t, knownApiaryIDs, nil)
}

// newActivitiesFixtureWithJourneys is newActivitiesFixture plus a fake
// journeys service (#46) seeded with knownJourneyIDs — the JourneyVerifier
// counterpart of knownApiaryIDs: a REST-create/sync-apply test that expects
// a SUCCESSFUL write carrying a journey_id must pass it here, otherwise the
// (correct) tenancy guard rejects it, exactly as it must for a real foreign
// org's journey.
func newActivitiesFixtureWithJourneys(t *testing.T, knownApiaryIDs, knownJourneyIDs []string) *activitiesFixture {
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
	knownJourneys := make(map[string]bool, len(knownJourneyIDs))
	for _, id := range knownJourneyIDs {
		knownJourneys[id] = true
	}
	fakeJourneys := newFakeJourneys(t, knownJourneys)
	journeyVerifier, err := api.NewJourneyVerifier(fakeJourneys.server.URL, fakeJourneys.server.Client())
	if err != nil {
		t.Fatalf("NewJourneyVerifier: %v", err)
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
	srv.Mount("/v1/activities", injectClaims(api.Router(pool, verifier, journeyVerifier)))
	srv.Mount("/internal/sync", injectClaims(api.InternalSyncRouter(pool, verifier, journeyVerifier)))

	return &activitiesFixture{srv: srv, pool: pool, apiaries: fakeApiaries, journeys: fakeJourneys}
}

func (f *activitiesFixture) do(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return f.doAs(t, "", method, path, body)
}

// doAs is do plus a synthetic caller: callerHeader ("sub|userID|orgID|role",
// via callerClaims) overrides injectClaims' devseed default so a single
// fixture/server can serve two distinct tenants in one test — the cross-org
// idiom mirrored from apiaries/main_test.go. An empty callerHeader is the
// devseed principal (org A).
func (f *activitiesFixture) doAs(t *testing.T, callerHeader, method, path string, body any) *httptest.ResponseRecorder {
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

// callerClaims builds the testOrgHeader value for a synthetic caller distinct
// from the devseed default (a second org/user for cross-org tests).
func callerClaims(sub, userID, orgID, role string) string {
	return strings.Join([]string{sub, userID, orgID, role}, "|")
}

// otherOrgCaller is a second, distinct principal (org B) used by the cross-org
// tests — a different sub/user/org from devseed's (org A), so the two calls in
// a test are genuinely two different tenants, not just two requests with the
// same claims. Same fixed ids apiaries/main_test.go uses for its own org B.
func otherOrgCaller() string {
	return callerClaims(
		"22222222-2222-4222-8222-222222222222",
		"a0000000-0000-7000-8000-000000000002",
		"b0000000-0000-7000-8000-000000000002",
		"admin",
	)
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

// TestActivitiesRest_Create_JourneyIdIsStoredWhenOwned proves the positive
// case of #46's journey_id ownership guard: a journey_id that DOES belong to
// the caller's org (registered with the fake journeys server) is accepted
// and persisted, end to end — the guard must reject a foreign id (the next
// test) without also rejecting a legitimate one.
func TestActivitiesRest_Create_JourneyIdIsStoredWhenOwned(t *testing.T) {
	apiaryID, journeyID := uuid.NewString(), uuid.NewString()
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, []string{journeyID})
	id := uuid.NewString()

	body := validHarvestBody(id, apiaryID)
	body["journey_id"] = journeyID
	rec := f.do(t, http.MethodPost, "/v1/activities", body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		JourneyID *string `json:"journey_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.JourneyID == nil || *got.JourneyID != journeyID {
		t.Fatalf("journey_id = %v, want %q", got.JourneyID, journeyID)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if !row.JourneyID.Valid || uuidString(row.JourneyID) != journeyID {
		t.Fatalf("stored journey_id = %+v, want %q", row.JourneyID, journeyID)
	}
}

// TestActivitiesRest_Create_CrossOrgJourneyIdIsRejected is the CRITICAL test
// this story exists to add (#46 review finding): before JourneyVerifier
// existed, journey_id was written with ZERO ownership verification — a
// journey_id that belongs to a DIFFERENT organization than the caller's
// resolved org must never be accepted, mirroring
// TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected exactly.
func TestActivitiesRest_Create_CrossOrgJourneyIdIsRejected(t *testing.T) {
	apiaryID := uuid.NewString()
	foreignJourneyID := uuid.NewString()
	// The fake journeys server is org-agnostic (mirrors the real GET
	// /v1/journeys/{id}'s scope-hiding) — not registering foreignJourneyID at
	// all models "belongs to another org" and "doesn't exist" as the
	// identical 404 (ADR-0002), either way the write must be rejected.
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, nil)
	id := uuid.NewString()

	body := validHarvestBody(id, apiaryID)
	body["journey_id"] = foreignJourneyID
	rec := f.do(t, http.MethodPost, "/v1/activities", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org/unknown journey_id must be rejected), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "journey_id", "not_found") {
		t.Fatalf("problem errors = %+v, want journey_id/not_found", p.Errors)
	}

	// Nothing must have been written — the tenancy guard runs BEFORE the
	// insert, exactly like the apiary_id guard, so a rejected cross-org
	// journey_id leaves no activity row at all (not even one with a null
	// journey_id).
	q := sqlcgen.New(f.pool)
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetActivity found a row after a rejected cross-org journey_id create — the write must not have happened")
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

// TestActivitiesSync_Apply_NonCanonicalCaseApiaryIdStillApplies is the
// regression guard for the review finding that resolveApiaryOwnership keyed
// `owned` by the RAW, unnormalized client string, while applyActivityOp
// looked it up via the CANONICAL uuid.Parse(...).String() form — so an
// apiary_id sent in a non-canonical case (e.g. uppercase hex, still a
// perfectly valid, owned UUID) would silently no-op the whole op (result
// "applied" but nothing actually written) even though the up-front
// ownership check HAD confirmed it belongs to the caller's org. The row
// must actually be created, not just report "applied".
func TestActivitiesSync_Apply_NonCanonicalCaseApiaryIdStillApplies(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID) // fake apiaries server knows the canonical (lowercase) form
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOp(id, strings.ToUpper(apiaryID))}}

	validateRec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if validateRec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", validateRec.Code, validateRec.Body.String())
	}
	applyRec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if applyRec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", applyRec.Code, applyRec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err != nil {
		t.Fatalf("GetActivity: %v — the op must have actually created the row, not silently no-op'd it", err)
	}
}

// TestActivitiesSync_Apply_NonCanonicalCaseJourneyIdStillApplies is the
// journey_id-side counterpart of the apiary_id regression above:
// resolveJourneyOwnership had the identical raw-key/normalized-lookup
// mismatch.
func TestActivitiesSync_Apply_NonCanonicalCaseJourneyIdStillApplies(t *testing.T) {
	apiaryID, journeyID := uuid.NewString(), uuid.NewString()
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, []string{journeyID})
	id := uuid.NewString()
	op := syncOp(id, apiaryID)
	op["data"].(map[string]any)["journey_id"] = strings.ToUpper(journeyID)
	batch := map[string]any{"ops": []any{op}}

	validateRec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if validateRec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", validateRec.Code, validateRec.Body.String())
	}
	applyRec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if applyRec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", applyRec.Code, applyRec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v — the op must have actually created the row, not silently no-op'd it", err)
	}
	if !row.JourneyID.Valid || uuidString(row.JourneyID) != journeyID {
		t.Fatalf("stored journey_id = %+v, want %q", row.JourneyID, journeyID)
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

// syncOpWithJourney is syncOp plus a journey_id (#46) on the op's data.
func syncOpWithJourney(id, apiaryID, journeyID string) map[string]any {
	op := syncOp(id, apiaryID)
	data := op["data"].(map[string]any)
	data["journey_id"] = journeyID
	return op
}

// TestActivitiesSync_ValidateThenApply_JourneyIdIsStoredWhenOwned is the
// sync-path positive case of #46's journey_id ownership guard, mirroring
// TestActivitiesRest_Create_JourneyIdIsStoredWhenOwned.
func TestActivitiesSync_ValidateThenApply_JourneyIdIsStoredWhenOwned(t *testing.T) {
	apiaryID, journeyID := uuid.NewString(), uuid.NewString()
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, []string{journeyID})
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOpWithJourney(id, apiaryID, journeyID)}}

	if rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch); rec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch); rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if !row.JourneyID.Valid || uuidString(row.JourneyID) != journeyID {
		t.Fatalf("stored journey_id = %+v, want %q", row.JourneyID, journeyID)
	}
}

// TestActivitiesSync_Validate_RejectsCrossOrgJourneyId is the sync-path
// counterpart of TestActivitiesRest_Create_CrossOrgJourneyIdIsRejected — the
// offline queue must not be able to bypass the journey_id tenancy guard
// either.
func TestActivitiesSync_Validate_RejectsCrossOrgJourneyId(t *testing.T) {
	apiaryID := uuid.NewString()
	foreignJourneyID := uuid.NewString()
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, nil)
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOpWithJourney(id, apiaryID, foreignJourneyID)}}

	rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org/unknown journey_id), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "ops[0].data.journey_id", "not_found") {
		t.Fatalf("problem errors = %+v, want ops[0].data.journey_id/not_found", p.Errors)
	}
}

// TestActivitiesSync_Apply_CrossOrgJourneyIdIsNoOp is applyActivityOp's #46
// journey_id counterpart of TestActivitiesSync_Apply_CrossOrgApiaryIdIsNoOp:
// apply re-checks ownership independently of validate, and a rejected op
// writes NOTHING — not even an activity row with journey_id dropped to null.
func TestActivitiesSync_Apply_CrossOrgJourneyIdIsNoOp(t *testing.T) {
	apiaryID := uuid.NewString()
	foreignJourneyID := uuid.NewString()
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, nil)
	id := uuid.NewString()
	batch := map[string]any{"ops": []any{syncOpWithJourney(id, apiaryID, foreignJourneyID)}}

	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200 (unknown/foreign journey_id is a no-op, not an error), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetActivity found a row for a cross-org journey_id op — it must have been a no-op")
	}
}

// TestActivitiesSync_Apply_DedupesJourneyOwnershipCalls is
// resolveJourneyOwnership's own regression guard, mirroring
// TestActivitiesSync_Apply_DedupesApiaryOwnershipCalls: three ops all
// against the SAME journey must hit the (fake) journeys service exactly
// ONCE.
func TestActivitiesSync_Apply_DedupesJourneyOwnershipCalls(t *testing.T) {
	apiaryID, journeyID := uuid.NewString(), uuid.NewString()
	f := newActivitiesFixtureWithJourneys(t, []string{apiaryID}, []string{journeyID})
	batch := map[string]any{"ops": []any{
		syncOpWithJourney(uuid.NewString(), apiaryID, journeyID),
		syncOpWithJourney(uuid.NewString(), apiaryID, journeyID),
		syncOpWithJourney(uuid.NewString(), apiaryID, journeyID),
	}}

	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if got := f.journeys.hitCount(journeyID); got != 1 {
		t.Fatalf("journeys ownership calls for journey %s = %d, want exactly 1 (batch must de-dup ownership checks, one call per distinct journey, not per op)", journeyID, got)
	}
}

// --- PATCH /v1/activities/{id} (#40, FR-AC-3) ---

func TestActivitiesRest_Update_Success(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/activities/"+id, map[string]any{
		"type":        api.TypeHarvest,
		"occurred_at": "2026-07-17",
		"attributes":  map[string]any{"honey_supers": 9, "honey_kg": 20},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		OccurredAt string         `json:"occurred_at"`
		Attributes map[string]any `json:"attributes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.OccurredAt != "2026-07-17" || got.Attributes["honey_supers"] != float64(9) {
		t.Fatalf("updated activity = %+v, want occurred_at=2026-07-17, honey_supers=9", got)
	}
}

// TestActivitiesRest_Update_ValidationRejectsBadInput proves updateActivity
// re-runs ValidateActivity server-side (#40 AC: "edited attributes are
// validated against the type's schema before saving") — a required
// attribute (harvest's honey_supers) dropped on edit must be rejected
// exactly like it would be on create.
func TestActivitiesRest_Update_ValidationRejectsBadInput(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/activities/"+id, map[string]any{
		"type":        api.TypeHarvest,
		"occurred_at": "2026-07-17",
		"attributes":  map[string]any{"honey_kg": 20},
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (missing required honey_supers on edit), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "attributes.honey_supers", "required") {
		t.Fatalf("problem errors = %+v, want attributes.honey_supers/required", p.Errors)
	}
}

// TestActivitiesRest_Update_CrossOrgApiaryIdIsRejected is #40's carry-over of
// the CRITICAL cross-tenant guard (mirrors
// TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected): re-pointing an
// activity at an apiary_id that doesn't belong to the caller's org must be
// rejected, and the stored row must be left completely unchanged.
func TestActivitiesRest_Update_CrossOrgApiaryIdIsRejected(t *testing.T) {
	apiaryID := uuid.NewString()
	foreignApiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID) // foreignApiaryID deliberately NOT known
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/activities/"+id, map[string]any{
		"apiary_id":   foreignApiaryID,
		"type":        api.TypeHarvest,
		"occurred_at": "2026-07-17",
		"attributes":  map[string]any{"honey_supers": 9},
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org apiary_id on edit must be rejected), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "apiary_id", "not_found") {
		t.Fatalf("problem errors = %+v, want apiary_id/not_found", p.Errors)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if uuidString(row.ApiaryID) != apiaryID || row.OccurredAt.Time.Format("2006-01-02") != "2026-07-16" {
		t.Fatalf("stored activity = %+v, want unchanged (apiary_id=%s, occurred_at=2026-07-16)", row, apiaryID)
	}
}

func TestActivitiesRest_Update_UnknownIdIsNotFound(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	rec := f.do(t, http.MethodPatch, "/v1/activities/"+uuid.NewString(), map[string]any{
		"type": api.TypeGeneric, "occurred_at": "2026-07-16", "attributes": map[string]any{},
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown activity id, body = %s", rec.Code, rec.Body.String())
	}
}

func TestActivitiesRest_History_UpdateProducesAuditRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodPatch, "/v1/activities/"+id, map[string]any{
		"type": api.TypeHarvest, "occurred_at": "2026-07-17", "attributes": map[string]any{"honey_supers": 9},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
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
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + update, FR-HIS-1)", len(rows))
	}
	if rows[1].ChangeType != "update" {
		t.Fatalf("second audit row change_type = %q, want update", rows[1].ChangeType)
	}
	if uuidString(rows[1].ActorUserID) != devseed.UserID {
		t.Fatalf("audit actor_user_id = %q, want the editing user %q (FR-HIS-1: actor + timestamp)", uuidString(rows[1].ActorUserID), devseed.UserID)
	}
}

// --- DELETE /v1/activities/{id} (#41, FR-AC-4) ---

func TestActivitiesRest_Delete_Success(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodDelete, "/v1/activities/"+id, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetActivity found the deleted activity — deleted_at IS NULL filter must exclude it")
	}
}

// TestActivitiesRest_Delete_TombstoneRowExcludedFromListQuery is #41's core
// AC ("the deleted activity no longer appears in apiary or all-apiaries
// lists"): the row must be SOFT-deleted (deleted_at set, still physically
// present) AND excluded from ListActivitiesByOrg/ListActivitiesByApiary —
// the same tombstone convention the PowerSync sync rule's own
// `deleted_at IS NULL` filter relies on to propagate the delete to devices.
func TestActivitiesRest_Delete_TombstoneRowExcludedFromListQuery(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	keepID := uuid.NewString()
	deleteID := uuid.NewString()
	for _, id := range []string{keepID, deleteID} {
		if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
			t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
		}
	}

	if rec := f.do(t, http.MethodDelete, "/v1/activities/"+deleteID, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}

	// Soft-deleted, not hard-deleted: the row is still physically there —
	// GetActivityForUpdate carries no deleted_at filter (sync.go's LWW
	// lookup), so it must still find it, with deleted_at now set.
	row, err := q.GetActivityForUpdate(context.Background(), sqlcgen.GetActivityForUpdateParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(deleteID), Valid: true}})
	if err != nil {
		t.Fatalf("GetActivityForUpdate: %v (the tombstoned row must still physically exist)", err)
	}
	if !row.DeletedAt.Valid {
		t.Fatalf("deleted_at is not set on the tombstoned row — expected a soft-delete, not a no-op")
	}

	// Excluded from both list queries (FR-AC-4 AC).
	byOrg, err := q.ListActivitiesByOrg(context.Background(), sqlcgen.ListActivitiesByOrgParams{OrganizationID: org, Limit: 50})
	if err != nil {
		t.Fatalf("ListActivitiesByOrg: %v", err)
	}
	if len(byOrg) != 1 || uuidString(byOrg[0].ID) != keepID {
		t.Fatalf("ListActivitiesByOrg = %d rows, want exactly the surviving activity (%s)", len(byOrg), keepID)
	}
	byApiary, err := q.ListActivitiesByApiary(context.Background(), sqlcgen.ListActivitiesByApiaryParams{
		OrganizationID: org, ApiaryID: pgtype.UUID{Bytes: uuid.MustParse(apiaryID), Valid: true}, Limit: 50,
	})
	if err != nil {
		t.Fatalf("ListActivitiesByApiary: %v", err)
	}
	if len(byApiary) != 1 || uuidString(byApiary[0].ID) != keepID {
		t.Fatalf("ListActivitiesByApiary = %d rows, want exactly the surviving activity (%s)", len(byApiary), keepID)
	}
}

func TestActivitiesRest_Delete_UnknownIdIsNotFound(t *testing.T) {
	f := newActivitiesFixture(t)
	rec := f.do(t, http.MethodDelete, "/v1/activities/"+uuid.NewString(), nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown activity id, body = %s", rec.Code, rec.Body.String())
	}
}

func TestActivitiesRest_Delete_AlreadyDeletedIsNotFound(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/activities/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("first delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodDelete, "/v1/activities/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("second delete status = %d, want 404 (already gone), body = %s", rec.Code, rec.Body.String())
	}
}

// TestActivitiesRest_CrossOrg_WritesCannotTouchOtherOrgsRow is the REST-level
// IDOR regression guard the code-reviewer and security-reviewer flagged as
// missing on PR #304 (#40/#41): the existing cross-org tests only cover a
// FOREIGN apiary_id on a SAME-org activity (Update_CrossOrgApiaryIdIsRejected)
// and unknown-id 404s — none exercise org B calling PATCH/DELETE against an
// activity id that ACTUALLY belongs to org A. Org B must get a 404 for both
// (scope-hiding, ADR-0002 — a foreign row is indistinguishable from a
// non-existent one), and org A's row must be left completely unchanged and NOT
// tombstoned. Mirrors apiaries' TestApiariesRest_CrossOrg_WritesCannotTouchOtherOrgsRow
// and the store-level TestActivitiesStore_GetActivity_CrossOrgReadReturnsNoRows.
// The underlying queries are already org-scoped (WHERE organization_id = $1 AND
// id = $2), so this is regression protection, not a live-bug fix.
func TestActivitiesRest_CrossOrg_WritesCannotTouchOtherOrgsRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	other := otherOrgCaller()

	// Org A (the devseed default) creates the activity.
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("org A create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	// Org B knows the real id but must not be able to edit or delete it: the
	// org-scoped lookup finds nothing for org B, so both come back 404.
	recUpdate := f.doAs(t, other, http.MethodPatch, "/v1/activities/"+id, map[string]any{
		"type": api.TypeGeneric, "occurred_at": "2026-07-17", "attributes": map[string]any{},
	})
	if recUpdate.Code != http.StatusNotFound {
		t.Fatalf("org B update status = %d, want 404 (scope-hiding, ADR-0002), body = %s", recUpdate.Code, recUpdate.Body.String())
	}
	recDelete := f.doAs(t, other, http.MethodDelete, "/v1/activities/"+id, nil)
	if recDelete.Code != http.StatusNotFound {
		t.Fatalf("org B delete status = %d, want 404 (scope-hiding, ADR-0002), body = %s", recDelete.Code, recDelete.Body.String())
	}

	// Org A's row is untouched: still readable in its org scope (so not
	// tombstoned — GetActivity filters deleted_at IS NULL), and its content is
	// exactly as created (org B's patch payload must not have leaked in).
	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetActivity for org A after cross-org attempts: %v (the row must survive untouched)", err)
	}
	if row.Type != api.TypeHarvest || uuidString(row.ApiaryID) != apiaryID || row.OccurredAt.Time.Format(dateLayoutForTest) != "2026-07-16" {
		t.Fatalf("org A activity = %+v, want unchanged (type=harvest, apiary_id=%s, occurred_at=2026-07-16)", row, apiaryID)
	}

	// Explicitly assert no tombstone was written by org B's DELETE — the
	// deleted_at-agnostic lookup must find the row with deleted_at still unset.
	forUpdate, err := q.GetActivityForUpdate(context.Background(), sqlcgen.GetActivityForUpdateParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetActivityForUpdate: %v", err)
	}
	if forUpdate.DeletedAt.Valid {
		t.Fatalf("deleted_at is set on org A's row — org B's cross-org DELETE must not have tombstoned it")
	}
}

func TestActivitiesRest_History_DeleteProducesAuditRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/activities/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
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
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + delete, FR-HIS-1)", len(rows))
	}
	if rows[1].ChangeType != "delete" {
		t.Fatalf("second audit row change_type = %q, want delete", rows[1].ChangeType)
	}
	if uuidString(rows[1].ActorUserID) != devseed.UserID {
		t.Fatalf("audit actor_user_id = %q, want the deleting user %q (FR-HIS-1: actor + timestamp)", uuidString(rows[1].ActorUserID), devseed.UserID)
	}
}

// --- GET /v1/activities/{id}/history (#60, FR-HIS-1) ---

// historyEntryView mirrors api/history.go's historyEntryDTO wire shape —
// this test file's own decode target (can't import the api package's
// unexported type across packages).
type historyEntryView struct {
	ID            string          `json:"id"`
	EntityType    string          `json:"entity_type"`
	EntityID      string          `json:"entity_id"`
	EventKind     string          `json:"event_kind"`
	ActorUserID   *string         `json:"actor_user_id"`
	OccurredAt    time.Time       `json:"occurred_at"`
	RecordedAt    time.Time       `json:"recorded_at"`
	ChangedFields []string        `json:"changed_fields"`
	Change        json.RawMessage `json:"change"`
}

type historyListView struct {
	Data []historyEntryView `json:"data"`
}

func (f *activitiesFixture) getActivityHistory(t *testing.T, id string) *httptest.ResponseRecorder {
	t.Helper()
	return f.do(t, http.MethodGet, "/v1/activities/"+id+"/history", nil)
}

// TestActivitiesRest_History_GetReturnsCombinedTimelineChronologically is
// #60's core AC: GET /v1/activities/{id}/history exposes the combined
// audit_log+sync_conflict_log timeline ListEntityTimeline builds (mirroring
// apiaries' own #61/#60 read) — create/update/delete via the REST write
// paths, then read it back over HTTP in chronological (recorded_at) order,
// oldest first.
func TestActivitiesRest_History_GetReturnsCombinedTimelineChronologically(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()

	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPatch, "/v1/activities/"+id, map[string]any{
		"type": api.TypeGeneric, "occurred_at": "2026-07-17", "attributes": map[string]any{},
	}); rec.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/activities/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.getActivityHistory(t, id)
	if rec.Code != http.StatusOK {
		t.Fatalf("history status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got historyListView
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode history response: %v", err)
	}
	if len(got.Data) != 3 {
		t.Fatalf("history entries = %d, want 3 (create, update, delete): %+v", len(got.Data), got.Data)
	}
	wantKinds := []string{"create", "update", "delete"}
	for i, want := range wantKinds {
		e := got.Data[i]
		if e.EventKind != want {
			t.Fatalf("history[%d].EventKind = %q, want %q", i, e.EventKind, want)
		}
		if e.EntityType != "activity" || e.EntityID != id {
			t.Fatalf("history[%d] entity = (%q,%q), want (activity,%q)", i, e.EntityType, e.EntityID, id)
		}
		if e.ActorUserID == nil || *e.ActorUserID != devseed.UserID {
			t.Fatalf("history[%d].ActorUserID = %v, want %q", i, e.ActorUserID, devseed.UserID)
		}
		if e.OccurredAt.IsZero() || e.RecordedAt.IsZero() {
			t.Fatalf("history[%d] has a zero timestamp: %+v", i, e)
		}
	}
	if len(got.Data[1].ChangedFields) == 0 {
		t.Fatalf("update entry ChangedFields = %v, want at least one changed field", got.Data[1].ChangedFields)
	}
	if !got.Data[0].RecordedAt.Before(got.Data[1].RecordedAt) || !got.Data[1].RecordedAt.Before(got.Data[2].RecordedAt) {
		t.Fatalf("history entries not chronologically ordered: %+v", got.Data)
	}
}

// TestActivitiesRest_History_ConflictSurfacesAsSupersededOverHTTP proves the
// #60 REST endpoint surfaces an LWW-losing offline edit as a "superseded"
// event (history.md §6), not silently missing — the HTTP counterpart of
// TestActivitiesSync_Apply_Delete_OlderThanLastEditIsSuperseded's own
// conflict scenario, but for a patch-vs-patch race read back via the new
// history route instead of asserted directly against the DB.
func TestActivitiesRest_History_ConflictSurfacesAsSupersededOverHTTP(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()

	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{syncOp(id, apiaryID)}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	// A newer edit lands first (11:00) and wins.
	winningOp := map[string]any{
		"op": "patch", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z",
		"data":       map[string]any{"type": api.TypeGeneric, "occurred_at": "2026-07-17", "attributes": map[string]any{"notes": "winner"}},
	}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{winningOp}}); rec.Code != http.StatusOK {
		t.Fatalf("winning patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	// An older queued edit (10:30, between the create's 10:00 and the
	// winning edit's 11:00) arrives after — it loses.
	losingOp := map[string]any{
		"op": "patch", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T10:30:00Z",
		"data":       map[string]any{"type": api.TypeFeeding, "occurred_at": "2026-07-16", "attributes": map[string]any{"notes": "loser"}},
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{losingOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("losing patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var applyResult struct {
		Results []struct {
			Result string `json:"result"`
		} `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &applyResult); err != nil {
		t.Fatalf("decode apply response: %v", err)
	}
	if len(applyResult.Results) != 1 || applyResult.Results[0].Result != "superseded" {
		t.Fatalf("losing patch result = %+v, want one superseded op", applyResult.Results)
	}

	histRec := f.getActivityHistory(t, id)
	if histRec.Code != http.StatusOK {
		t.Fatalf("history status = %d, want 200, body = %s", histRec.Code, histRec.Body.String())
	}
	var got historyListView
	if err := json.Unmarshal(histRec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode history response: %v", err)
	}
	if len(got.Data) != 3 {
		t.Fatalf("history entries = %d, want 3 (create, winning update, superseded loss): %+v", len(got.Data), got.Data)
	}
	last := got.Data[2]
	if last.EventKind != history.EventSuperseded {
		t.Fatalf("last entry EventKind = %q, want %q", last.EventKind, history.EventSuperseded)
	}
	if last.ChangedFields != nil {
		t.Fatalf("superseded entry ChangedFields = %v, want nil (only audit_log rows carry it)", last.ChangedFields)
	}
	var change map[string]any
	if err := json.Unmarshal(last.Change, &change); err != nil {
		t.Fatalf("unmarshal superseded change: %v", err)
	}
	if change["winner"] != "server" {
		t.Fatalf("superseded change[winner] = %v, want server", change["winner"])
	}
}

// TestActivitiesRest_History_NotFound_UnknownID: a history request for an id
// that was never created 404s, same as the REST create/edit/delete paths.
func TestActivitiesRest_History_NotFound_UnknownID(t *testing.T) {
	f := newActivitiesFixture(t)
	rec := f.getActivityHistory(t, uuid.NewString())
	if rec.Code != http.StatusNotFound {
		t.Fatalf("history status for unknown id = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestActivitiesRest_History_CrossOrg_NotFound is the #60 IDOR regression:
// org B must not be able to read org A's activity history by id — the same
// CRITICAL cross-org guard TestActivitiesRest_CrossOrg_WritesCannotTouchOtherOrgsRow
// proves for edit/delete (#284/#39 carry-over), now proven for the new
// history route too, so it never regresses that fix. 404 (ADR-0002
// scope-hiding), not an empty-but-200 body (which would still leak "this id
// exists in some org").
func TestActivitiesRest_History_CrossOrg_NotFound(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/activities", validHarvestBody(id, apiaryID)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	other := otherOrgCaller()
	rec := f.doAs(t, other, http.MethodGet, "/v1/activities/"+id+"/history", nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-org history status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// --- /internal/sync validate/apply — edit (#40) ---

func TestActivitiesSync_Apply_Patch_UpdatesActivity(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	createBatch := map[string]any{"ops": []any{syncOp(id, apiaryID)}}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", createBatch); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	patchOp := map[string]any{
		"op": "patch", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z", // strictly newer than the create's 10:00:00Z
		"data": map[string]any{
			"type": api.TypeGeneric, "occurred_at": "2026-07-17",
			"attributes": map[string]any{"notes": "edited offline"},
		},
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{patchOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Results []struct {
			Result string `json:"result"`
		} `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Results) != 1 || got.Results[0].Result != "applied" {
		t.Fatalf("patch results = %+v, want one applied op", got.Results)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if row.Type != api.TypeGeneric || row.OccurredAt.Time.Format(dateLayoutForTest) != "2026-07-17" {
		t.Fatalf("row after patch = %+v, want type=generic occurred_at=2026-07-17", row)
	}
	// apiary_id must be unchanged — the patch op deliberately doesn't carry
	// one (#40's optional-apiary_id convention: an edit that doesn't touch it
	// leaves the stored value alone).
	if uuidString(row.ApiaryID) != apiaryID {
		t.Fatalf("apiary_id after patch = %q, want unchanged %q", uuidString(row.ApiaryID), apiaryID)
	}
}

// TestActivitiesSync_Apply_Patch_CrossOrgApiaryIdIsNoOp proves the ownership
// guard still fires on an EDIT that DOES carry an apiary_id (#40's own
// review note: "re-verify apiary ownership"), even though the common edit
// case never sends one at all.
func TestActivitiesSync_Apply_Patch_CrossOrgApiaryIdIsNoOp(t *testing.T) {
	apiaryID := uuid.NewString()
	foreignApiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID) // foreignApiaryID deliberately not known
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{syncOp(id, apiaryID)}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	patchOp := map[string]any{
		"op": "patch", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z",
		"data": map[string]any{
			"apiary_id": foreignApiaryID, "type": api.TypeGeneric, "occurred_at": "2026-07-17",
			"attributes": map[string]any{},
		},
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{patchOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200 (cross-org apiary_id on patch is a no-op, not an error), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v", err)
	}
	if row.Type != api.TypeGeneric {
		t.Fatalf("row was mutated despite the rejected cross-org apiary_id — the patch must have been a full no-op")
	}
	if uuidString(row.ApiaryID) != apiaryID {
		t.Fatalf("apiary_id = %q, want unchanged %q (cross-org apiary_id must never be written)", uuidString(row.ApiaryID), apiaryID)
	}
}

func TestActivitiesSync_Validate_Patch_RejectsInvalidAttributes(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	patchOp := map[string]any{
		"op": "patch", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z",
		"data": map[string]any{
			"type": api.TypeHarvest, "occurred_at": "2026-07-17",
			"attributes": map[string]any{"honey_kg": 5}, // missing required honey_supers
		},
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", map[string]any{"ops": []any{patchOp}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (missing required honey_supers), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "ops[0].data.attributes.honey_supers", "required") {
		t.Fatalf("problem errors = %+v, want ops[0].data.attributes.honey_supers/required", p.Errors)
	}
}

// --- /internal/sync validate/apply — delete/tombstone (#41) ---

func TestActivitiesSync_Apply_Delete_TombstonesRow(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{syncOp(id, apiaryID)}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	deleteOp := map[string]any{
		"op": "delete", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z",
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
	if _, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}}); err == nil {
		t.Fatalf("GetActivity found the tombstoned row — deleted_at IS NULL filter must exclude it")
	}
	row, err := q.GetActivityForUpdate(context.Background(), sqlcgen.GetActivityForUpdateParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetActivityForUpdate: %v (soft-deleted row must still physically exist)", err)
	}
	if !row.DeletedAt.Valid {
		t.Fatalf("deleted_at not set — expected a tombstone, not a hard delete")
	}
	rows, err := q.ListActivitiesByOrg(context.Background(), sqlcgen.ListActivitiesByOrgParams{OrganizationID: org, Limit: 50})
	if err != nil {
		t.Fatalf("ListActivitiesByOrg: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("ListActivitiesByOrg = %d rows, want 0 (the tombstoned row must not appear)", len(rows))
	}
}

func TestActivitiesSync_Apply_Delete_MissingRowIsNoOp(t *testing.T) {
	f := newActivitiesFixture(t)
	deleteOp := map[string]any{
		"op": "delete", "entity_type": "activity", "id": uuid.NewString(),
		"updated_at": "2026-07-16T11:00:00Z",
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (deleting an id the server never had is a no-op), body = %s", rec.Code, rec.Body.String())
	}
}

// TestActivitiesSync_Apply_Delete_IdempotentReplay is the offline op
// idempotency test: PowerSync's own forward-retry (sync.md §6.2) can resend
// the SAME queued delete op more than once (e.g. the client never saw the
// first 200 due to a dropped response) — the second application must be a
// pure no-op (still applied, no duplicate audit row, no conflict logged),
// never an error and never a second tombstone attempt.
func TestActivitiesSync_Apply_Delete_IdempotentReplay(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{syncOp(id, apiaryID)}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	deleteOp := map[string]any{
		"op": "delete", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z",
	}
	batch := map[string]any{"ops": []any{deleteOp}}

	first := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if first.Code != http.StatusOK {
		t.Fatalf("first delete apply status = %d, want 200, body = %s", first.Code, first.Body.String())
	}
	second := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if second.Code != http.StatusOK {
		t.Fatalf("replayed delete apply status = %d, want 200, body = %s", second.Code, second.Body.String())
	}
	var got struct {
		Results []struct {
			Result string `json:"result"`
		} `json:"results"`
	}
	if err := json.Unmarshal(second.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Results) != 1 || got.Results[0].Result != "applied" {
		t.Fatalf("replayed delete result = %+v, want one applied op (idempotent, not superseded)", got.Results)
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
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + ONE delete — the replay must not add a second delete row)", len(rows))
	}
}

// TestActivitiesSync_Apply_Delete_OlderThanLastEditIsSuperseded is the LWW
// safety-net test for a delete that loses: a delete queued from a device
// that was offline before a newer edit landed must not clobber that newer
// edit (sync.md §4.1/§4.2 — the delete is logged as a conflict, not
// silently dropped, and the row survives).
func TestActivitiesSync_Apply_Delete_OlderThanLastEditIsSuperseded(t *testing.T) {
	apiaryID := uuid.NewString()
	f := newActivitiesFixture(t, apiaryID)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{syncOp(id, apiaryID)}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	// A newer edit lands first (11:00), THEN an older queued delete (10:30,
	// between the create's 10:00 and the edit's 11:00) arrives.
	patchOp := map[string]any{
		"op": "patch", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T11:00:00Z",
		"data":       map[string]any{"type": api.TypeGeneric, "occurred_at": "2026-07-17", "attributes": map[string]any{}},
	}
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{patchOp}}); rec.Code != http.StatusOK {
		t.Fatalf("patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	deleteOp := map[string]any{
		"op": "delete", "entity_type": "activity", "id": id,
		"updated_at": "2026-07-16T10:30:00Z",
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
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
		t.Fatalf("stale delete result = %+v, want one superseded op (LWW: the newer edit must win)", got.Results)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetActivity(context.Background(), sqlcgen.GetActivityParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetActivity: %v (the row must have survived — the delete lost the LWW compare)", err)
	}
	if row.Type != api.TypeGeneric {
		t.Fatalf("surviving row type = %q, want %q (the newer edit's content, not clobbered by the stale delete)", row.Type, api.TypeGeneric)
	}
}

const dateLayoutForTest = "2006-01-02"
