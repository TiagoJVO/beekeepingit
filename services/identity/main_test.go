package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/identity/api"
	"github.com/TiagoJVO/beekeepingit/services/identity/store"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/identity/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn/authtest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

const testAudience = "beekeepingit-identity"

// TestIdentityService_ResolveBySub wires the service as run() does and
// exercises the internal resolve endpoint over real HTTP against a real
// Postgres: unauthenticated is rejected, the seeded sub resolves to its
// user row, and an unknown sub is a 404.
func TestIdentityService_ResolveBySub(t *testing.T) {
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

	dbCfg := dbaccess.Config{
		Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable",
	}
	// Migrations no longer create the schema (that's infra's job in-cluster);
	// provision it here as the postgres chart's bootstrap would.
	createSchema(ctx, t, dbCfg, "identity")
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	if err := store.Seed(ctx, pool); err != nil {
		t.Fatalf("seed: %v", err)
	}

	idp := authtest.NewIDP(t)
	authnMW, err := authn.NewMiddleware(ctx, authn.Config{IssuerURL: idp.Issuer(), Audience: testAudience})
	if err != nil {
		t.Fatalf("build authn middleware: %v", err)
	}

	cfg := config.Config{ServiceName: "identity-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })

	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/internal", authnMW(api.InternalRouter(pool)))

	get := func(path, auth string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		srv.Router().ServeHTTP(rec, req)
		return rec
	}

	// Unauthenticated → 401.
	if rec := get("/internal/users/by-sub/"+devseed.OidcSub, ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}

	token := idp.Mint(t, devseed.OidcSub, testAudience)

	// Seeded sub → 200 with the resolved user.
	rec := get("/internal/users/by-sub/"+devseed.OidcSub, "Bearer "+token)
	if rec.Code != http.StatusOK {
		t.Fatalf("resolve status = %d, want %d, body = %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	var got api.UserResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.UserID != devseed.UserID {
		t.Errorf("user_id = %q, want %q", got.UserID, devseed.UserID)
	}
	if got.OidcSub != devseed.OidcSub {
		t.Errorf("oidc_sub = %q, want %q", got.OidcSub, devseed.OidcSub)
	}

	// Unknown sub → 404.
	unknown := idp.Mint(t, "00000000-0000-0000-0000-000000000000", testAudience)
	if rec := get("/internal/users/by-sub/00000000-0000-0000-0000-000000000000", "Bearer "+unknown); rec.Code != http.StatusNotFound {
		t.Errorf("unknown sub status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

// TestGetUserByOidcSub_ResolvesOnRenamedColumn is the focused guard for the
// oidc_sub column rename (00002, oidc-integration.md §6): it migrates
// the full chain (so 00002's ALTER ... RENAME COLUMN actually runs), seeds the
// dev user, and calls the regenerated GetUserByOidcSub directly — proving the
// query targets the renamed column and that a seeded `sub` resolves to its row
// while an unknown one is pgx.ErrNoRows. The HTTP-level resolve path is covered
// by TestIdentityService_ResolveBySub above; this pins the query/column itself.
func TestGetUserByOidcSub_ResolvesOnRenamedColumn(t *testing.T) {
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

	dbCfg := dbaccess.Config{
		Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable",
	}
	createSchema(ctx, t, dbCfg, "identity")
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	if err := store.Seed(ctx, pool); err != nil {
		t.Fatalf("seed: %v", err)
	}

	q := sqlcgen.New(pool)

	// The seeded sub resolves via the renamed column to the seeded user row.
	u, err := q.GetUserByOidcSub(ctx, devseed.OidcSub)
	if err != nil {
		t.Fatalf("GetUserByOidcSub(seeded): %v", err)
	}
	if u.OidcSub != devseed.OidcSub {
		t.Errorf("OidcSub = %q, want %q", u.OidcSub, devseed.OidcSub)
	}
	if got := uuid.UUID(u.ID.Bytes).String(); got != devseed.UserID {
		t.Errorf("resolved user id = %q, want %q", got, devseed.UserID)
	}

	// An unknown sub is a clean no-rows, not some other error.
	if _, err := q.GetUserByOidcSub(ctx, "99999999-9999-4999-8999-999999999999"); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("GetUserByOidcSub(unknown) error = %v, want pgx.ErrNoRows", err)
	}
}

// TestIdentitySchema_UsersIsTheDocumentedTenancyException is the automated
// form of FR-TEN-2's "every owned row carries an organization_id" check
// (dbaccess.UnscopedTables, shared across services, added in #30) for this
// service: identity.users is the one documented tenancy exception (a global
// identity table, ADR-0002) rather than something owned by an organization,
// so it's passed as the exempt table — the assertion is that it's still the
// *only* unscoped table, i.e. a future migration adding some other
// identity-owned table without organization_id fails this test instead of
// depending on a manual read (#175).
func TestIdentitySchema_UsersIsTheDocumentedTenancyException(t *testing.T) {
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

	dbCfg := dbaccess.Config{
		Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable",
	}
	createSchema(ctx, t, dbCfg, "identity")
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	unscoped, err := dbaccess.UnscopedTables(ctx, pool, "identity", "users")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(unscoped) != 0 {
		t.Fatalf("identity schema has table(s) missing organization_id beyond the documented users exception: %v", unscoped)
	}
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
	// Parameterized/sanitized rather than raw string concatenation (coding
	// standards: "parameterized queries only") — a schema name can't be a
	// bind parameter (DDL doesn't accept them), so pgx.Identifier.Sanitize
	// is the equivalent safeguard for an identifier. name is always a
	// literal ("identity") today, but this keeps the helper consistent with
	// the convention even if a future caller passes something less trusted.
	stmt := fmt.Sprintf("CREATE SCHEMA IF NOT EXISTS %s", pgx.Identifier{name}.Sanitize())
	if _, err := conn.Exec(ctx, stmt); err != nil {
		t.Fatalf("create schema %s: %v", name, err)
	}
}
