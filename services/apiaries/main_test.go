package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
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
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

// injectClaims stands in for the authn + org-resolver chain so these tests
// exercise the read + sync-apply logic directly with a known org/user.
func injectClaims(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := authn.ContextWithClaims(r.Context(), authn.Claims{
			Sub:            devseed.KeycloakSub,
			UserID:         devseed.UserID,
			OrganizationID: devseed.OrganizationID,
			Role:           devseed.MembershipRole,
		})
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

func (f *apiariesFixture) apply(t *testing.T, ops ...api.Op) api.ApplyResponse {
	t.Helper()
	rec := f.do(t, http.MethodPost, "/internal/sync/apply", api.Batch{Ops: ops})
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
