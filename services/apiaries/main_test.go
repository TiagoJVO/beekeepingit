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
	"github.com/jackc/pgx/v5/pgxpool"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/apiaries/api"
	"github.com/TiagoJVO/beekeepingit/services/apiaries/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

// testOrgHeader lets a test request stand in as a caller resolved to a
// different org/user/role than the devseed default — the only way these
// in-process tests can exercise TestApiariesSlice_CrossOrg* (#28 AC:
// "automated tests including cross-organization access attempts") without a
// live identity/organizations pair to resolve against. It's a test-only
// escape hatch on the fake injectClaims middleware, never read by
// production code (authn.NewOrgResolver derives Claims from the verified
// token + membership, never a header).
const testOrgHeader = "X-Test-Org-Claims"

// injectClaims stands in for the authn + org-resolver chain so these tests
// exercise the read + sync-apply logic directly with a known org/user. By
// default it uses the devseed principal; a request carrying testOrgHeader
// ("sub|userID|orgID|role") overrides it, so a single fixture/server can
// serve two distinct callers in the same test (cross-org assertions).
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

type apiariesFixture struct {
	srv  *servicetemplate.Server
	pool *pgxpool.Pool
}

func newApiariesFixture(t *testing.T) *apiariesFixture {
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
	// Migrations no longer create the schema (infra's job in-cluster).
	createSchema(ctx, t, dbCfg, "apiaries")
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	cfg := config.Config{ServiceName: "apiaries-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })
	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/v1/apiaries", injectClaims(api.ReadRouter(pool)))
	srv.Mount("/internal/sync", injectClaims(api.InternalSyncRouter(pool)))

	return &apiariesFixture{srv: srv, pool: pool}
}

func (f *apiariesFixture) do(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return f.doAs(t, "", method, path, body)
}

// doAs is like do, but callerHeader (built by callerClaims) stands the
// request in as a different resolved caller — the escape hatch
// injectClaims reads to let a single fixture serve two distinct
// orgs/users/roles in one test (cross-org assertions, #28 AC).
func (f *apiariesFixture) doAs(t *testing.T, callerHeader, method, path string, body any) *httptest.ResponseRecorder {
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

// callerClaims builds the testOrgHeader value for a synthetic caller
// distinct from the devseed default (a second org/user for cross-org tests).
func callerClaims(sub, userID, orgID, role string) string {
	return strings.Join([]string{sub, userID, orgID, role}, "|")
}

func (f *apiariesFixture) apply(t *testing.T, ops ...api.Op) api.ApplyResponse {
	t.Helper()
	return f.applyAs(t, "", ops...)
}

func (f *apiariesFixture) applyAs(t *testing.T, callerHeader string, ops ...api.Op) api.ApplyResponse {
	t.Helper()
	rec := f.doAs(t, callerHeader, http.MethodPost, "/internal/sync/apply", api.Batch{Ops: ops})
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var out api.ApplyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode apply response: %v", err)
	}
	return out
}

func (f *apiariesFixture) conflictCount(t *testing.T) int {
	t.Helper()
	var n int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM apiaries.sync_conflict_log").Scan(&n); err != nil {
		t.Fatalf("count conflicts: %v", err)
	}
	return n
}

func putOp(id, name string, hive int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"name": name, "hive_count": hive})
	return api.Op{Op: "put", EntityType: "apiary", ID: id, Data: data, UpdatedAt: ts}
}

func patchHive(id string, hive int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"hive_count": hive})
	return api.Op{Op: "patch", EntityType: "apiary", ID: id, Data: data, UpdatedAt: ts}
}

// TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone walks the whole
// apply/read matrix the skeleton must guarantee (sync.md §4–§5).
func TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// ① Create (put) → applied, and readable via the client-facing read path.
	if got := f.apply(t, putOp(id, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	if a := f.getApiary(t, id); a.Name != "Encosta Nova" || a.HiveCount != 0 {
		t.Fatalf("read after create = %+v", a)
	}

	// ② Newer edit wins.
	if got := f.apply(t, patchHive(id, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("newer edit result = %q, want applied", got.Results[0].Result)
	}
	if a := f.getApiary(t, id); a.HiveCount != 12 {
		t.Fatalf("hive_count after newer edit = %d, want 12", a.HiveCount)
	}

	// ③ Older edit loses → superseded, server value kept, conflict logged.
	if got := f.apply(t, patchHive(id, 99, t0.Add(-time.Minute))); got.Results[0].Result != "superseded" {
		t.Fatalf("older edit result = %q, want superseded", got.Results[0].Result)
	}
	if a := f.getApiary(t, id); a.HiveCount != 12 {
		t.Fatalf("hive_count after superseded edit = %d, want 12 (server kept)", a.HiveCount)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows = %d, want 1", n)
	}

	// ④ Idempotent re-send of the winning edit → applied, no new conflict, no change.
	if got := f.apply(t, patchHive(id, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("idempotent re-send result = %q, want applied", got.Results[0].Result)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows after idempotent re-send = %d, want 1", n)
	}

	// ⑤ Delete (tombstone) → applied; hidden from read.
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(2 * time.Minute)}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}
	if rec := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("get after delete status = %d, want 404", rec.Code)
	}
	if list := f.listApiaries(t); len(list.Data) != 0 {
		t.Fatalf("list after delete = %d rows, want 0", len(list.Data))
	}
}

func TestApiariesSlice_ValidateRejectsBadOps(t *testing.T) {
	f := newApiariesFixture(t)
	// put with empty name is invalid.
	bad := api.Op{Op: "put", EntityType: "apiary", ID: uuid.NewString(),
		Data: json.RawMessage(`{"name":""}`), UpdatedAt: time.Now()}
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", api.Batch{Ops: []api.Op{bad}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("validate status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
}

// otherOrgCaller is a second, distinct principal (org B) used by the
// cross-org tests below — a different sub/user/org from devseed's (org A),
// so the two calls in each test are genuinely two different tenants, not
// just two requests with the same claims.
func otherOrgCaller() string {
	return callerClaims(
		"22222222-2222-4222-8222-222222222222",
		"a0000000-0000-7000-8000-000000000002",
		"b0000000-0000-7000-8000-000000000002",
		"admin",
	)
}

// TestApiariesSlice_CrossOrg_GetReturns404NotFound is the #28 AC's
// "requests for resources outside the caller's organization are denied
// (403/404)" case for apiaries: org B must not be able to read org A's
// apiary by id, and the response must be 404 (ADR-0002 scope-hiding), not a
// distinguishable "exists but forbidden" signal.
func TestApiariesSlice_CrossOrg_GetReturns404NotFound(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// devseed's org (org A) creates an apiary.
	if got := f.apply(t, putOp(id, "Org A Apiary", 5, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}

	// Org B (a different caller entirely) tries to read it directly by id.
	other := otherOrgCaller()
	rec := f.doAs(t, other, http.MethodGet, "/v1/apiaries/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-org get status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestApiariesSlice_CrossOrg_ListNeverIncludesOtherOrgsRows guards the list
// endpoint the same way: org B's list must never contain org A's rows, even
// though both orgs have data.
func TestApiariesSlice_CrossOrg_ListNeverIncludesOtherOrgsRows(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	other := otherOrgCaller()

	idA := uuid.NewString()
	if got := f.apply(t, putOp(idA, "Org A Apiary", 1, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org A apiary result = %q, want applied", got.Results[0].Result)
	}
	idB := uuid.NewString()
	if got := f.applyAs(t, other, putOp(idB, "Org B Apiary", 2, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org B apiary result = %q, want applied", got.Results[0].Result)
	}

	// Org A's list contains only its own apiary.
	listA := f.listApiaries(t)
	if len(listA.Data) != 1 || listA.Data[0].ID != idA {
		t.Fatalf("org A list = %+v, want exactly [%s]", listA.Data, idA)
	}

	// Org B's list contains only its own apiary — never org A's.
	rec := f.doAs(t, other, http.MethodGet, "/v1/apiaries", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("org B list status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var listB listView
	if err := json.Unmarshal(rec.Body.Bytes(), &listB); err != nil {
		t.Fatalf("decode org B list: %v", err)
	}
	if len(listB.Data) != 1 || listB.Data[0].ID != idB {
		t.Fatalf("org B list = %+v, want exactly [%s]", listB.Data, idB)
	}
}

// TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow is the write
// half of the same guarantee: org B's sync-apply batch addressing org A's
// apiary id must not mutate — or delete — it. GetApiaryForUpdate is
// org-scoped (sync.go's applyOp), so from org B's perspective org A's row
// simply doesn't exist; a delete op against it is the safe, PK-collision-free
// way to prove that (applyOp's "missing row + delete ⇒ nothing to tombstone"
// branch never touches the database). A put/patch op would instead attempt
// an INSERT reusing org A's id as the (bare, non-org-scoped) primary key,
// which collides at the DB level — a real but separate schema question
// (whether apiaries.apiaries should be keyed by (organization_id, id)) that's
// #30's tenancy-model territory, not this test's concern. Confirms FR-TEN-2
// holds on the write path, not just reads.
func TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	other := otherOrgCaller()

	id := uuid.NewString()
	if got := f.apply(t, putOp(id, "Org A Apiary", 5, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org A apiary result = %q, want applied", got.Results[0].Result)
	}

	// Org B "deletes" org A's id — from org B's org-scoped view the row
	// doesn't exist, so this must be a no-op against the database, not an
	// actual delete of org A's apiary.
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(time.Minute)}
	if got := f.applyAs(t, other, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("org B delete-of-unknown-id result = %q, want applied (no-op)", got.Results[0].Result)
	}

	// Org A's own apiary is untouched and still live.
	if a := f.getApiary(t, id); a.HiveCount != 5 {
		t.Fatalf("org A apiary hive_count = %d, want 5 (untouched by org B's delete attempt)", a.HiveCount)
	}

	// Org B still can't see it either (it was never org B's to begin with).
	recB := f.doAs(t, other, http.MethodGet, "/v1/apiaries/"+id, nil)
	if recB.Code != http.StatusNotFound {
		t.Fatalf("org B get status = %d, want 404, body = %s", recB.Code, recB.Body.String())
	}
}

// TestApiariesSchema_EveryOwnedTableCarriesOrganizationID is the automated
// form of #30's AC "every owned row (apiary, activity, journey, and other
// org-owned entities) carries an organization_id": rather than a one-time
// manual read of the migration files, this runs against the real, migrated
// apiaries schema so a future migration that adds a table without
// organization_id fails CI (dbaccess.UnscopedTables, shared across services).
// apiaries has no exempt (tenant-root/global-identity) tables of its own —
// unlike identity.users or organizations.organizations — so every base
// table here is expected to be scoped.
func TestApiariesSchema_EveryOwnedTableCarriesOrganizationID(t *testing.T) {
	f := newApiariesFixture(t)

	unscoped, err := dbaccess.UnscopedTables(context.Background(), f.pool, "apiaries")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(unscoped) != 0 {
		t.Fatalf("apiaries schema has table(s) missing organization_id: %v", unscoped)
	}
}

// TestApiariesSlice_ResponsesConformToOpenAPIContract exercises the
// client-facing read surface (GET /v1/apiaries[/{id}]) through the real
// server and validates each response against contracts/openapi/apiaries —
// the "contract tests at boundaries" AC of #153. It's a boundary test, not a
// functional one: TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone
// already covers the read/apply semantics this reuses.
func TestApiariesSlice_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/apiaries.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if got := f.apply(t, putOp(id, "Quinta do Vale", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}

	getPath := "/v1/apiaries/" + id
	recGet := f.do(t, http.MethodGet, getPath, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("get status = %d, want 200", recGet.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, getPath, http.StatusOK, recGet.Body.Bytes())

	recList := f.do(t, http.MethodGet, "/v1/apiaries", nil)
	if recList.Code != http.StatusOK {
		t.Fatalf("list status = %d, want 200", recList.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/apiaries", http.StatusOK, recList.Body.Bytes())

	// A deleted resource's 404 must still be a well-formed Problem response.
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(time.Minute)}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}
	recGone := f.do(t, http.MethodGet, getPath, nil)
	if recGone.Code != http.StatusNotFound {
		t.Fatalf("get-after-delete status = %d, want 404", recGone.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, getPath, http.StatusNotFound, recGone.Body.Bytes())
}

// --- small read helpers ---

type apiaryView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	HiveCount int32  `json:"hive_count"`
}

func (f *apiariesFixture) getApiary(t *testing.T, id string) apiaryView {
	t.Helper()
	rec := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var a apiaryView
	if err := json.Unmarshal(rec.Body.Bytes(), &a); err != nil {
		t.Fatalf("decode apiary: %v", err)
	}
	return a
}

type listView struct {
	Data []apiaryView `json:"data"`
	Page struct {
		NextCursor *string `json:"next_cursor"`
		Limit      int     `json:"limit"`
	} `json:"page"`
}

func (f *apiariesFixture) listApiaries(t *testing.T) listView {
	t.Helper()
	rec := f.do(t, http.MethodGet, "/v1/apiaries", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var l listView
	if err := json.Unmarshal(rec.Body.Bytes(), &l); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	return l
}

// createSchema provisions the service's schema before migrating, standing in
// for the postgres chart's bootstrap (migrations no longer create it).
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
