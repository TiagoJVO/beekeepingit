package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jackc/pgx/v5"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/organizations/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn/authtest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

const testAudience = "beekeepingit-organizations"

// TestOrganizationsService_ResolveActiveMembership wires the service as run()
// does and exercises the internal resolve endpoint over real HTTP against a
// real Postgres: unauthenticated is rejected, the seeded user resolves to its
// active membership (org + role), and an unknown user is a 404.
func TestOrganizationsService_ResolveActiveMembership(t *testing.T) {
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
	// Migrations no longer create the schema (infra's job in-cluster).
	createSchema(t, ctx, dbCfg, "organizations")
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

	cfg := config.Config{ServiceName: "organizations-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
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

	// Any valid token authenticates these internal calls; the sub is not the
	// membership key (user_id is), so authtest's default sub is fine.
	token := "Bearer " + idp.Mint(t, devseed.KeycloakSub, testAudience)

	// Unauthenticated → 401.
	if rec := get("/internal/memberships/active?user_id="+devseed.UserID, ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}

	// Seeded user → 200 with the active membership.
	rec := get("/internal/memberships/active?user_id="+devseed.UserID, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("resolve status = %d, want %d, body = %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	var got api.MembershipResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.OrganizationID != devseed.OrganizationID {
		t.Errorf("organization_id = %q, want %q", got.OrganizationID, devseed.OrganizationID)
	}
	if got.Role != devseed.MembershipRole {
		t.Errorf("role = %q, want %q", got.Role, devseed.MembershipRole)
	}

	// Unknown user → 404.
	if rec := get("/internal/memberships/active?user_id=00000000-0000-0000-0000-000000000000", token); rec.Code != http.StatusNotFound {
		t.Errorf("unknown user status = %d, want %d", rec.Code, http.StatusNotFound)
	}

	// Missing user_id → 422.
	if rec := get("/internal/memberships/active", token); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("missing user_id status = %d, want %d", rec.Code, http.StatusUnprocessableEntity)
	}
}

// createSchema provisions the service's schema before migrating, standing in
// for the postgres chart's bootstrap (migrations no longer create it).
func createSchema(t *testing.T, ctx context.Context, cfg dbaccess.Config, name string) {
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
