// Package main — integration tests for #50: the migrated schema shape
// (tenancy: every owned table carries organization_id, FR-TEN-2), the
// store-layer insert/read round trip and its cross-org isolation, the
// create/edit/complete/reopen/delete REST surface (FR-TD-1), the internal
// sync validate/apply endpoints (FR-OF-1), and the FR-HIS-1 audit trail.
// Uses a real, containerized Postgres (testcontainers), mirroring
// services/activities/main_test.go's own fixture conventions — plain
// postgres:16-alpine (this service has no PostGIS/JSONB-attribute columns).
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

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
	"github.com/TiagoJVO/beekeepingit/services/todos/api"
	"github.com/TiagoJVO/beekeepingit/services/todos/store"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/todos/store/sqlc/gen"
)

// testOrgHeader lets a test request stand in as a caller resolved to a
// different org/user/role than the devseed default — mirrors
// activities/main_test.go's identical helper, the only way these in-process
// tests can exercise a cross-organization request without a live
// identity/organizations pair to resolve against.
const testOrgHeader = "X-Test-Org-Claims"

// injectClaims stands in for the authn + org-resolver chain, mirroring
// activities/main_test.go's helper of the same name.
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

type todosFixture struct {
	srv           *servicetemplate.Server
	pool          *pgxpool.Pool
	organizations *fakeOrganizations
}

// fakeOrganizations stands in for the real organizations service's
// GET /internal/memberships/active?user_id=<uid> (api/members_client.go's
// MemberVerifier target): 200 {"organization_id": <mapped org>} for any
// user_id present in `memberships`, 404 otherwise — enough to exercise the
// CRITICAL cross-org assignee_id tenancy guard without standing up a second
// real service + database in this test binary. It also counts per-id hits
// so a test can prove the batch write path de-duplicates its ownership
// calls (one upstream call per distinct assignee, not one per op).
type fakeOrganizations struct {
	server *httptest.Server
	mu     sync.Mutex
	hits   map[string]int
}

func (f *fakeOrganizations) hitCount(userID string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[userID]
}

func newFakeOrganizations(t *testing.T, memberships map[string]string) *fakeOrganizations {
	t.Helper()
	f := &fakeOrganizations{hits: map[string]int{}}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		userID := r.URL.Query().Get("user_id")
		f.mu.Lock()
		f.hits[userID]++
		f.mu.Unlock()
		orgID, ok := memberships[userID]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"organization_id": orgID, "role": "user"})
	}))
	t.Cleanup(f.server.Close)
	return f
}

// newTodosFixture builds the test fixture. memberships (nil is fine — most
// tests below never touch assignee_id) maps an assignee user_id to the
// organization it has an active membership in — a REST-create/sync-apply
// test that expects a SUCCESSFUL assignment must map its assignee to
// devseed.OrganizationID; a cross-org test maps it to a DIFFERENT org id.
func newTodosFixture(t *testing.T, memberships map[string]string) *todosFixture {
	t.Helper()
	ctx := context.Background()

	if memberships == nil {
		memberships = map[string]string{}
	}
	fakeOrgs := newFakeOrganizations(t, memberships)
	verifier, err := api.NewMemberVerifier(fakeOrgs.server.URL, fakeOrgs.server.Client())
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
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
	createSchema(ctx, t, dbCfg, "todos")
	// SearchPath matches infra/helm's DB_SEARCH_PATH=todos (schema-per-
	// service, D-6), same convention as activities/apiaries/organizations.
	dbCfg.SearchPath = "todos"
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	cfg := config.Config{ServiceName: "todos-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })
	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/v1/todos", injectClaims(api.Router(pool, verifier)))
	srv.Mount("/internal/sync", injectClaims(api.InternalSyncRouter(pool, verifier)))

	return &todosFixture{srv: srv, pool: pool, organizations: fakeOrgs}
}

func (f *todosFixture) do(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return f.doAs(t, "", method, path, body)
}

// doAs is do plus a synthetic caller: callerHeader ("sub|userID|orgID|role",
// via callerClaims) overrides injectClaims' devseed default so a single
// fixture/server can serve two distinct tenants in one test — the cross-org
// idiom mirrored from activities/main_test.go. An empty callerHeader is the
// devseed principal (org A).
func (f *todosFixture) doAs(t *testing.T, callerHeader, method, path string, body any) *httptest.ResponseRecorder {
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

// otherOrgCaller is a second, distinct principal (org B) used by the
// cross-org tests — same fixed ids activities'/apiaries' own main_test.go
// use for their org B.
func otherOrgCaller() string {
	return callerClaims(
		"22222222-2222-4222-8222-222222222222",
		"a0000000-0000-7000-8000-000000000002",
		"b0000000-0000-7000-8000-000000000002",
		"admin",
	)
}

// createSchema provisions the service's schema before migrating, standing in
// for infra's postgres chart bootstrap (mirrors activities/apiaries/organizations).
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

// uuidString reads a stored pgtype.UUID column back as its string form —
// this test file's own copy of api's unexported helper of the same name
// (can't import an unexported identifier across packages).
func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

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

// --- Tenancy schema check (FR-TEN-2, mirrors activities'
// TestActivitiesSchema_EveryOwnedTableCarriesOrganizationID) ---

func TestTodosSchema_EveryOwnedTableCarriesOrganizationID(t *testing.T) {
	f := newTodosFixture(t, nil)
	unscoped, err := dbaccess.UnscopedTables(context.Background(), f.pool, "todos")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(unscoped) != 0 {
		t.Fatalf("tables missing organization_id = %v, want none (every owned table must carry organization_id, FR-TEN-2)", unscoped)
	}
}

func TestTodosMigration_ThreeTablesCreated(t *testing.T) {
	f := newTodosFixture(t, nil)
	for _, table := range []string{"todos", "audit_log", "sync_conflict_log"} {
		var exists bool
		err := f.pool.QueryRow(context.Background(), `
			SELECT EXISTS (
				SELECT 1 FROM information_schema.tables
				WHERE table_schema = 'todos' AND table_name = $1
			)`, table).Scan(&exists)
		if err != nil {
			t.Fatalf("query information_schema.tables for %s: %v", table, err)
		}
		if !exists {
			t.Fatalf("todos.%s table does not exist", table)
		}
	}
}

func TestTodosMigration_OrganizationIDNotNull(t *testing.T) {
	f := newTodosFixture(t, nil)
	_, err := f.pool.Exec(context.Background(), `
		INSERT INTO todos.todos (id, title, priority, updated_at)
		VALUES (gen_random_uuid(), 'x', 'low', now())`)
	if err == nil {
		t.Fatalf("insert with NULL organization_id unexpectedly succeeded — NOT NULL constraint not enforced at the DB level (FR-TEN-2)")
	}
}

// --- Store-layer insert/read + cross-org isolation (FR-TEN-2) ---

func TestTodosStore_InsertThenGet(t *testing.T) {
	f := newTodosFixture(t, nil)
	ctx := context.Background()
	q := sqlcgen.New(f.pool)

	org := newUUID(t)
	id := newUUID(t)
	row, err := q.InsertTodo(ctx, sqlcgen.InsertTodoParams{
		ID: id, OrganizationID: org, Title: "Check varroa levels",
		Priority: api.PriorityHigh, Status: api.StatusOpen,
		UpdatedAt: pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
	})
	if err != nil {
		t.Fatalf("InsertTodo: %v", err)
	}
	if row.Title != "Check varroa levels" || row.Priority != api.PriorityHigh || row.Status != api.StatusOpen {
		t.Fatalf("inserted row = %+v, want title/priority/status set", row)
	}

	got, err := q.GetTodo(ctx, sqlcgen.GetTodoParams{OrganizationID: org, ID: id})
	if err != nil {
		t.Fatalf("GetTodo: %v", err)
	}
	if got.Title != "Check varroa levels" {
		t.Fatalf("GetTodo title = %q, want %q", got.Title, "Check varroa levels")
	}
}

func TestTodosStore_CrossOrgIsolation(t *testing.T) {
	f := newTodosFixture(t, nil)
	ctx := context.Background()
	q := sqlcgen.New(f.pool)

	orgA := newUUID(t)
	orgB := newUUID(t)
	id := newUUID(t)
	if _, err := q.InsertTodo(ctx, sqlcgen.InsertTodoParams{
		ID: id, OrganizationID: orgA, Title: "Org A todo", Priority: api.PriorityLow, Status: api.StatusOpen,
		UpdatedAt: pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
	}); err != nil {
		t.Fatalf("InsertTodo: %v", err)
	}

	// Org B looks up org A's todo id — must find nothing (FR-TEN-2).
	if _, err := q.GetTodo(ctx, sqlcgen.GetTodoParams{OrganizationID: orgB, ID: id}); err == nil {
		t.Fatalf("GetTodo across orgs unexpectedly succeeded, want no rows")
	} else if err != pgx.ErrNoRows {
		t.Fatalf("GetTodo across orgs error = %v, want pgx.ErrNoRows", err)
	}
}

// --- POST /v1/todos (FR-TD-1) ---

func validTodoBody(id string) map[string]any {
	return map[string]any{
		"id":       id,
		"title":    "Inspect hive 3",
		"priority": api.PriorityMedium,
	}
}

func TestTodosRest_Create_Success(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		ID       string `json:"id"`
		Title    string `json:"title"`
		Priority string `json:"priority"`
		Status   string `json:"status"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v, body = %s", err, rec.Body.String())
	}
	if got.ID != id || got.Title != "Inspect hive 3" || got.Priority != api.PriorityMedium || got.Status != api.StatusOpen {
		t.Fatalf("created todo = %+v, want id=%s title=%q priority=%s status=%s", got, id, "Inspect hive 3", api.PriorityMedium, api.StatusOpen)
	}
}

func TestTodosRest_Create_MissingTitleIsRejected(t *testing.T) {
	f := newTodosFixture(t, nil)
	rec := f.do(t, http.MethodPost, "/v1/todos", map[string]any{
		"id": uuid.NewString(), "priority": api.PriorityMedium,
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (missing title), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "title", "required") {
		t.Fatalf("problem errors = %+v, want title/required", p.Errors)
	}
}

func TestTodosRest_Create_UnknownPriorityIsRejected(t *testing.T) {
	f := newTodosFixture(t, nil)
	rec := f.do(t, http.MethodPost, "/v1/todos", map[string]any{
		"id": uuid.NewString(), "title": "x", "priority": "urgent",
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (unknown priority), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "priority", "invalid") {
		t.Fatalf("problem errors = %+v, want priority/invalid", p.Errors)
	}
}

func TestTodosRest_Create_DefaultsToUnassignedAndOpen(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id))
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Status     string  `json:"status"`
		AssigneeID *string `json:"assignee_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != api.StatusOpen {
		t.Fatalf("status = %q, want %q (D-23: every new todo starts open)", got.Status, api.StatusOpen)
	}
	if got.AssigneeID != nil {
		t.Fatalf("assignee_id = %q, want nil (D-23: default unassigned)", *got.AssigneeID)
	}
}

func TestTodosRest_Create_WithAssignee_Verified(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: devseed.OrganizationID})
	id := uuid.NewString()
	body := validTodoBody(id)
	body["assignee_id"] = assignee

	rec := f.do(t, http.MethodPost, "/v1/todos", body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		AssigneeID *string `json:"assignee_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.AssigneeID == nil || *got.AssigneeID != assignee {
		t.Fatalf("assignee_id = %v, want %q", got.AssigneeID, assignee)
	}
}

// TestTodosRest_Create_CrossOrgAssigneeIsRejected is the CRITICAL IDOR test
// this PR exists to add (D-23's own cross-service verification requirement,
// mirroring activities' apiary_id carry-over of #284's cross-tenant IDOR
// fix): an assignee_id with an active membership in a DIFFERENT organization
// than the caller's must never be accepted.
func TestTodosRest_Create_CrossOrgAssigneeIsRejected(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: "b0000000-0000-7000-8000-000000000099"})
	id := uuid.NewString()
	body := validTodoBody(id)
	body["assignee_id"] = assignee

	rec := f.do(t, http.MethodPost, "/v1/todos", body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org assignee_id must be rejected), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "assignee_id", "not_found") {
		t.Fatalf("problem errors = %+v, want assignee_id/not_found", p.Errors)
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetTodo found a row after a rejected cross-org create — the write must not have happened")
	}
}

func TestTodosRest_Create_IdempotentReplayDoesNotDuplicate(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	body := validTodoBody(id)

	first := f.do(t, http.MethodPost, "/v1/todos", body)
	if first.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	second := f.do(t, http.MethodPost, "/v1/todos", body)
	if second.Code != http.StatusCreated {
		t.Fatalf("replayed create status = %d, want 201 (idempotent replay), body = %s", second.Code, second.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("audit rows after idempotent replay = %d, want 1 (no duplicate create)", len(rows))
	}
}

func TestTodosRest_Create_DifferentContentSameIdIsConflict(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()

	first := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id))
	if first.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	changed := validTodoBody(id)
	changed["title"] = "A completely different title"
	second := f.do(t, http.MethodPost, "/v1/todos", changed)
	if second.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 (same id, different content), body = %s", second.Code, second.Body.String())
	}
}

// --- PATCH /v1/todos/{id} (FR-TD-1) ---

func TestTodosRest_Update_ChangesFieldsAndRecordsHistory(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/todos/"+id, map[string]any{
		"title": "Inspect hive 3 — urgent", "description": "check for mites",
		"due_date": "2026-08-01", "priority": api.PriorityHigh,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Title       string  `json:"title"`
		Description *string `json:"description"`
		DueDate     *string `json:"due_date"`
		Priority    string  `json:"priority"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Title != "Inspect hive 3 — urgent" || got.Description == nil || *got.Description != "check for mites" ||
		got.DueDate == nil || *got.DueDate != "2026-08-01" || got.Priority != api.PriorityHigh {
		t.Fatalf("updated todo = %+v", got)
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
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
}

func TestTodosRest_Update_CrossOrgAssigneeIsRejected(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: "b0000000-0000-7000-8000-000000000099"})
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/todos/"+id, map[string]any{
		"title": "x", "priority": api.PriorityMedium, "assignee_id": assignee,
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org assignee_id on edit must be rejected), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "assignee_id", "not_found") {
		t.Fatalf("problem errors = %+v, want assignee_id/not_found", p.Errors)
	}
}

// TestTodosRest_Update_ClearAssignee_NoVerificationCall proves clearing an
// existing assignee (omitting assignee_id from a resubmit) writes NULL with
// NO new upstream membership call — updateTodo's own doc comment.
func TestTodosRest_Update_ClearAssignee_NoVerificationCall(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: devseed.OrganizationID})
	id := uuid.NewString()
	body := validTodoBody(id)
	body["assignee_id"] = assignee
	if rec := f.do(t, http.MethodPost, "/v1/todos", body); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if got := f.organizations.hitCount(assignee); got != 1 {
		t.Fatalf("membership calls after create = %d, want 1", got)
	}

	rec := f.do(t, http.MethodPatch, "/v1/todos/"+id, map[string]any{
		"title": "x", "priority": api.PriorityMedium, // assignee_id omitted → clear
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		AssigneeID *string `json:"assignee_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.AssigneeID != nil {
		t.Fatalf("assignee_id = %q, want nil after clearing", *got.AssigneeID)
	}
	if got := f.organizations.hitCount(assignee); got != 1 {
		t.Fatalf("membership calls after clearing assignee = %d, want still 1 (no verification call on clear)", got)
	}
}

func TestTodosRest_Update_UnknownIdIsNotFound(t *testing.T) {
	f := newTodosFixture(t, nil)
	rec := f.do(t, http.MethodPatch, "/v1/todos/"+uuid.NewString(), map[string]any{
		"title": "x", "priority": api.PriorityLow,
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown todo id, body = %s", rec.Code, rec.Body.String())
	}
}

// --- POST /v1/todos/{id}/complete + /reopen (FR-TD-1) ---

func TestTodosRest_Complete_SetsStatusDoneAndCompletedAt(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/complete", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Status      string     `json:"status"`
		CompletedAt *time.Time `json:"completed_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != api.StatusDone || got.CompletedAt == nil {
		t.Fatalf("completed todo = %+v, want status=done and completed_at set", got)
	}
}

func TestTodosRest_Reopen_ClearsCompletedAt(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/complete", nil); rec.Code != http.StatusOK {
		t.Fatalf("complete status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/reopen", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Status      string     `json:"status"`
		CompletedAt *time.Time `json:"completed_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != api.StatusOpen || got.CompletedAt != nil {
		t.Fatalf("reopened todo = %+v, want status=open and completed_at cleared", got)
	}
}

func TestTodosRest_Complete_PreservesOtherFields(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	body := validTodoBody(id)
	body["description"] = "double check frames"
	body["due_date"] = "2026-08-01"
	if rec := f.do(t, http.MethodPost, "/v1/todos", body); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/complete", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Title       string  `json:"title"`
		Description *string `json:"description"`
		DueDate     *string `json:"due_date"`
		Priority    string  `json:"priority"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Title != "Inspect hive 3" || got.Description == nil || *got.Description != "double check frames" ||
		got.DueDate == nil || *got.DueDate != "2026-08-01" || got.Priority != api.PriorityMedium {
		t.Fatalf("completed todo lost other fields = %+v", got)
	}
}

func TestTodosRest_CompleteThenReopen_IsIdempotent(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/complete", nil); rec.Code != http.StatusOK {
		t.Fatalf("first complete status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	// Repeating complete on an already-done todo is a no-op — 200, not an error.
	if rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/complete", nil); rec.Code != http.StatusOK {
		t.Fatalf("second complete status = %d, want 200 (idempotent), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + ONE complete — the repeat must not add a second row)", len(rows))
	}
}

// --- DELETE /v1/todos/{id} (FR-TD-1) ---

func TestTodosRest_Delete_TombstoneRowExcludedFromGet(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodDelete, "/v1/todos/"+id, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
	if _, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}}); err == nil {
		t.Fatalf("GetTodo found the deleted todo — deleted_at IS NULL filter must exclude it")
	}
	row, err := q.GetTodoForUpdate(context.Background(), sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetTodoForUpdate: %v (the tombstoned row must still physically exist)", err)
	}
	if !row.DeletedAt.Valid {
		t.Fatalf("deleted_at is not set on the tombstoned row — expected a soft-delete, not a no-op")
	}
}

func TestTodosRest_Delete_UnknownIdIsNotFound(t *testing.T) {
	f := newTodosFixture(t, nil)
	rec := f.do(t, http.MethodDelete, "/v1/todos/"+uuid.NewString(), nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 for an unknown todo id, body = %s", rec.Code, rec.Body.String())
	}
}

func TestTodosRest_Delete_AlreadyDeletedIsNotFound(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/todos/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("first delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodDelete, "/v1/todos/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("second delete status = %d, want 404 (already gone), body = %s", rec.Code, rec.Body.String())
	}
}

// TestTodosRest_CrossOrg_WritesCannotTouchOtherOrgsRow is the REST-level IDOR
// regression guard this repo's review culture has flagged as a MANDATORY
// companion to any cross-org write path (mirrors activities'
// TestActivitiesRest_CrossOrg_WritesCannotTouchOtherOrgsRow, #309): org B
// must get 404 for update/complete/delete against org A's todo id, and org
// A's row must be left completely unchanged.
func TestTodosRest_CrossOrg_WritesCannotTouchOtherOrgsRow(t *testing.T) {
	f := newTodosFixture(t, nil)
	other := otherOrgCaller()

	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("org A create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	if rec := f.doAs(t, other, http.MethodPatch, "/v1/todos/"+id, map[string]any{"title": "x", "priority": api.PriorityLow}); rec.Code != http.StatusNotFound {
		t.Fatalf("org B update status = %d, want 404 (scope-hiding, ADR-0002), body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.doAs(t, other, http.MethodPost, "/v1/todos/"+id+"/complete", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("org B complete status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.doAs(t, other, http.MethodDelete, "/v1/todos/"+id, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("org B delete status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
	row, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetTodo for org A after cross-org attempts: %v (the row must survive untouched)", err)
	}
	if row.Title != "Inspect hive 3" || row.Status != api.StatusOpen {
		t.Fatalf("org A todo = %+v, want unchanged (title=%q, status=%s)", row, "Inspect hive 3", api.StatusOpen)
	}
}

// --- Attribution + history (FR-TEN-2, FR-HIS-1) ---

func TestTodosRest_Attribution_ActorFromClaimsNeverClientSupplied(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("audit rows = %d, want 1 (FR-HIS-1)", len(rows))
	}
	if uuidString(rows[0].ActorUserID) != devseed.UserID {
		t.Fatalf("audit actor_user_id = %q, want the creating user %q (FR-HIS-1: actor + timestamp, never client-supplied)", uuidString(rows[0].ActorUserID), devseed.UserID)
	}
}

func TestTodosHistory_CreateEditCompleteReopenDelete_EachRecordsRow(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/todos", validTodoBody(id)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPatch, "/v1/todos/"+id, map[string]any{"title": "edited", "priority": api.PriorityLow}); rec.Code != http.StatusOK {
		t.Fatalf("update status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/complete", nil); rec.Code != http.StatusOK {
		t.Fatalf("complete status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/todos/"+id+"/reopen", nil); rec.Code != http.StatusOK {
		t.Fatalf("reopen status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, "/v1/todos/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	wantTypes := []string{"create", "update", "update", "update", "delete"}
	if len(rows) != len(wantTypes) {
		t.Fatalf("audit rows = %d, want %d %v (create/edit/complete/reopen/delete each record one row, FR-HIS-1)", len(rows), len(wantTypes), wantTypes)
	}
	for i, want := range wantTypes {
		if rows[i].ChangeType != want {
			t.Fatalf("audit row[%d].change_type = %q, want %q", i, rows[i].ChangeType, want)
		}
	}
}

// --- /internal/sync validate/apply (FR-OF-1/Q-SYNC — offline lifecycle) ---

// todoSyncOp builds one sync-batch op. data may be nil (a delete op carries
// none).
func todoSyncOp(op, id, updatedAt string, data map[string]any) map[string]any {
	m := map[string]any{"op": op, "entity_type": "todo", "id": id, "updated_at": updatedAt}
	if data != nil {
		m["data"] = data
	}
	return m
}

func TestTodosSync_ValidateThenApply_Create_Success(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	op := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{
		"title": "Queued offline todo", "priority": api.PriorityMedium, "status": api.StatusOpen,
	})
	batch := map[string]any{"ops": []any{op}}

	if rec := f.do(t, http.MethodPost, "/internal/sync/validate", batch); rec.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	applyRec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if applyRec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", applyRec.Code, applyRec.Body.String())
	}
	var got struct {
		Results []struct {
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
	row, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetTodo: %v", err)
	}
	if row.Title != "Queued offline todo" {
		t.Fatalf("row.Title = %q, want %q", row.Title, "Queued offline todo")
	}
}

func TestTodosSync_Validate_RejectsCrossOrgAssignee(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: "b0000000-0000-7000-8000-000000000099"})
	id := uuid.NewString()
	op := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{
		"title": "x", "priority": api.PriorityMedium, "assignee_id": assignee,
	})
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", map[string]any{"ops": []any{op}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (cross-org assignee_id), body = %s", rec.Code, rec.Body.String())
	}
	p := decodeProblem(t, rec)
	if !problemHasFieldCode(p, "ops[0].data.assignee_id", "not_found") {
		t.Fatalf("problem errors = %+v, want ops[0].data.assignee_id/not_found", p.Errors)
	}
}

func TestTodosSync_Apply_CrossOrgAssigneeIsNoOp(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: "b0000000-0000-7000-8000-000000000099"})
	id := uuid.NewString()
	op := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{
		"title": "x", "priority": api.PriorityMedium, "assignee_id": assignee,
	})
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{op}})
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200 (cross-org assignee_id is a no-op, not an error), body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	if _, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	}); err == nil {
		t.Fatalf("GetTodo found a row for a cross-org assignee_id op — it must have been a no-op")
	}
}

func TestTodosSync_Apply_Patch_LWWNewerWins(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	createOp := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{"title": "x", "priority": api.PriorityLow})
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{createOp}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	patchOp := todoSyncOp("patch", id, "2026-07-16T11:00:00Z", map[string]any{"title": "y", "priority": api.PriorityHigh})
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
	row, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetTodo: %v", err)
	}
	if row.Title != "y" || row.Priority != api.PriorityHigh {
		t.Fatalf("row after newer patch = %+v, want title=y priority=high", row)
	}
}

func TestTodosSync_Apply_Patch_OlderLosesAndLogsConflict(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	createOp := todoSyncOp("put", id, "2026-07-16T11:00:00Z", map[string]any{"title": "current", "priority": api.PriorityMedium})
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{createOp}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	staleOp := todoSyncOp("patch", id, "2026-07-16T10:00:00Z", map[string]any{"title": "stale", "priority": api.PriorityLow})
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{staleOp}})
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
		t.Fatalf("stale patch result = %+v, want one superseded op (LWW: the newer create must win)", got.Results)
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetTodo: %v (the row must have survived unchanged)", err)
	}
	if row.Title != "current" {
		t.Fatalf("row.Title = %q, want unchanged %q (the stale edit must lose)", row.Title, "current")
	}

	var count int
	if err := f.pool.QueryRow(context.Background(), `SELECT count(*) FROM todos.sync_conflict_log WHERE entity_id = $1`, uuid.MustParse(id)).Scan(&count); err != nil {
		t.Fatalf("query sync_conflict_log: %v", err)
	}
	if count != 1 {
		t.Fatalf("sync_conflict_log rows for this todo = %d, want 1 (history.md §6: LWW losers are not lost)", count)
	}
}

func TestTodosSync_Apply_Delete_TombstonesRow(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	createOp := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{"title": "x", "priority": api.PriorityMedium})
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{createOp}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	deleteOp := todoSyncOp("delete", id, "2026-07-16T11:00:00Z", nil)
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
	if _, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}}); err == nil {
		t.Fatalf("GetTodo found the tombstoned row — deleted_at IS NULL filter must exclude it")
	}
	row, err := q.GetTodoForUpdate(context.Background(), sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetTodoForUpdate: %v (soft-deleted row must still physically exist)", err)
	}
	if !row.DeletedAt.Valid {
		t.Fatalf("deleted_at not set — expected a tombstone, not a hard delete")
	}
}

func TestTodosSync_Apply_Delete_IdempotentReplay(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	createOp := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{"title": "x", "priority": api.PriorityMedium})
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{createOp}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	deleteOp := todoSyncOp("delete", id, "2026-07-16T11:00:00Z", nil)
	batch := map[string]any{"ops": []any{deleteOp}}

	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch); rec.Code != http.StatusOK {
		t.Fatalf("first delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
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
		EntityType:     "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + ONE delete — the replay must not add a second delete row)", len(rows))
	}
}

func TestTodosSync_Apply_Put_UndeletesUnderNewerLWW(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	createOp := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{"title": "x", "priority": api.PriorityMedium})
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{createOp}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	deleteOp := todoSyncOp("delete", id, "2026-07-16T11:00:00Z", nil)
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{deleteOp}}); rec.Code != http.StatusOK {
		t.Fatalf("delete apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	putOp := todoSyncOp("put", id, "2026-07-16T12:00:00Z", map[string]any{"title": "restored", "priority": api.PriorityHigh})
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{putOp}})
	if rec.Code != http.StatusOK {
		t.Fatalf("restoring put apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	row, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		ID:             pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true},
	})
	if err != nil {
		t.Fatalf("GetTodo: %v (a strictly-newer put must undelete the row)", err)
	}
	if row.Title != "restored" {
		t.Fatalf("row.Title = %q, want %q", row.Title, "restored")
	}
}

// TestTodosSync_Apply_CompleteViaPatch_RecordsUpdateHistory proves the
// package doc's central claim: an offline complete flows as an ordinary
// patch touching only status/completed_at, applied by the same LWW path as
// any edit, recorded as a plain history.ChangeUpdate row.
func TestTodosSync_Apply_CompleteViaPatch_RecordsUpdateHistory(t *testing.T) {
	f := newTodosFixture(t, nil)
	id := uuid.NewString()
	createOp := todoSyncOp("put", id, "2026-07-16T10:00:00Z", map[string]any{"title": "x", "priority": api.PriorityMedium})
	if rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{createOp}}); rec.Code != http.StatusOK {
		t.Fatalf("create apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	completePatch := todoSyncOp("patch", id, "2026-07-16T11:00:00Z", map[string]any{
		"status": api.StatusDone, "completed_at": "2026-07-16T11:00:00Z",
	})
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", map[string]any{"ops": []any{completePatch}})
	if rec.Code != http.StatusOK {
		t.Fatalf("complete-via-patch apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	q := sqlcgen.New(f.pool)
	org := pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true}
	row, err := q.GetTodo(context.Background(), sqlcgen.GetTodoParams{OrganizationID: org, ID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("GetTodo: %v", err)
	}
	if row.Status != api.StatusDone || !row.CompletedAt.Valid {
		t.Fatalf("row after complete-via-patch = %+v, want status=done and completed_at set", row)
	}
	if row.Title != "x" {
		t.Fatalf("title = %q, want unchanged %q (a status-only patch must not touch title)", row.Title, "x")
	}

	rows, err := q.ListAuditLog(context.Background(), sqlcgen.ListAuditLogParams{OrganizationID: org, EntityType: "todo", EntityID: pgtype.UUID{Bytes: uuid.MustParse(id), Valid: true}})
	if err != nil {
		t.Fatalf("ListAuditLog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + update)", len(rows))
	}
	if rows[1].ChangeType != "update" {
		t.Fatalf("second audit row change_type = %q, want update (no dedicated 'complete' change_type)", rows[1].ChangeType)
	}
	found := false
	for _, cf := range rows[1].ChangedFields {
		if cf == "status" {
			found = true
		}
	}
	if !found {
		t.Fatalf("changed_fields = %v, want to include status", rows[1].ChangedFields)
	}
}

// TestTodosSync_Apply_DedupesAssigneeOwnershipCalls is the regression guard
// for the same de-dup discipline activities' sync.go established: the
// per-op cross-service ownership call must be resolved ONCE per distinct
// assignee_id, up front, NOT once per op inside the DB transaction.
func TestTodosSync_Apply_DedupesAssigneeOwnershipCalls(t *testing.T) {
	assignee := uuid.NewString()
	f := newTodosFixture(t, map[string]string{assignee: devseed.OrganizationID})
	batch := map[string]any{"ops": []any{
		todoSyncOp("put", uuid.NewString(), "2026-07-16T10:00:00Z", map[string]any{"title": "a", "priority": api.PriorityLow, "assignee_id": assignee}),
		todoSyncOp("put", uuid.NewString(), "2026-07-16T10:00:00Z", map[string]any{"title": "b", "priority": api.PriorityLow, "assignee_id": assignee}),
		todoSyncOp("put", uuid.NewString(), "2026-07-16T10:00:00Z", map[string]any{"title": "c", "priority": api.PriorityLow, "assignee_id": assignee}),
	}}

	rec := f.do(t, http.MethodPost, "/internal/sync/apply", batch)
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if got := f.organizations.hitCount(assignee); got != 1 {
		t.Fatalf("organizations ownership calls for assignee %s = %d, want exactly 1 (batch must de-dup ownership checks, one call per distinct assignee, not per op)", assignee, got)
	}
}
