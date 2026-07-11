package dbaccess_test

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// newTenancyFixturePool starts a fresh Postgres container and creates a
// schema with a small, fixed set of tables — org-scoped, exempt, and
// neither — to exercise UnscopedTables against known-good and known-bad
// shapes without depending on any real service's migrations.
func newTenancyFixturePool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()
	const (
		user     = "beekeepingit_test"
		password = "beekeepingit_test"
		dbName   = "beekeepingit_test"
	)

	container, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithUsername(user),
		tcpostgres.WithPassword(password),
		tcpostgres.WithDatabase(dbName),
		tcpostgres.BasicWaitStrategies(),
	)
	if err != nil {
		t.Fatalf("start postgres container: %v", err)
	}
	t.Cleanup(func() {
		if err := container.Terminate(ctx); err != nil {
			t.Logf("terminate postgres container: %v", err)
		}
	})

	host, err := container.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := container.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}

	cfg := dbaccess.Config{Host: host, Port: port.Port(), User: user, Password: password, Database: dbName, SSLMode: "disable"}
	pool, err := dbaccess.Connect(ctx, cfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	// One statement per Exec call (not a single multi-statement string) to
	// match the rest of the codebase's pool.Exec usage
	// (services/organizations/store/seed.go) and avoid depending on whether
	// the driver's default query-execution mode accepts multiple
	// semicolon-separated statements in one round-trip.
	ddl := []string{
		`CREATE SCHEMA tenancy_fixture`,
		// Owned, correctly org-scoped.
		`CREATE TABLE tenancy_fixture.widgets (
			id UUID PRIMARY KEY,
			organization_id UUID NOT NULL,
			name TEXT NOT NULL
		)`,
		// The tenant root itself — exempt, like organizations.organizations.
		`CREATE TABLE tenancy_fixture.tenants (
			id UUID PRIMARY KEY,
			name TEXT NOT NULL
		)`,
		// A global identity table — exempt, like identity.users.
		`CREATE TABLE tenancy_fixture.people (
			id UUID PRIMARY KEY,
			email TEXT NOT NULL
		)`,
		// Owned, but MISSING organization_id — the bug this helper catches.
		`CREATE TABLE tenancy_fixture.gadgets (
			id UUID PRIMARY KEY,
			name TEXT NOT NULL
		)`,
		// A view, not a base table — must be ignored regardless of columns.
		`CREATE VIEW tenancy_fixture.widgets_view AS SELECT id, name FROM tenancy_fixture.widgets`,
	}
	for _, stmt := range ddl {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			t.Fatalf("create fixture schema (%q): %v", stmt, err)
		}
	}

	return pool
}

// TestUnscopedTables_FindsOwnedTableMissingOrgID is the core assertion #30's
// AC needs automated, not manually audited: an owned table with no
// organization_id column is flagged, exempt tables are not, and views are
// ignored.
func TestUnscopedTables_FindsOwnedTableMissingOrgID(t *testing.T) {
	pool := newTenancyFixturePool(t)

	got, err := dbaccess.UnscopedTables(context.Background(), pool, "tenancy_fixture", "tenants", "people")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(got) != 1 || got[0] != "gadgets" {
		t.Fatalf("UnscopedTables = %v, want exactly [gadgets]", got)
	}
}

// TestUnscopedTables_AllScopedOrExempt_ReturnsEmpty proves the healthy case
// doesn't false-positive once every owned table is scoped (or legitimately
// exempt).
func TestUnscopedTables_AllScopedOrExempt_ReturnsEmpty(t *testing.T) {
	pool := newTenancyFixturePool(t)

	got, err := dbaccess.UnscopedTables(context.Background(), pool, "tenancy_fixture", "tenants", "people", "gadgets")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("UnscopedTables = %v, want none (all exempted or scoped)", got)
	}
}
