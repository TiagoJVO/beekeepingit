package dbaccess_test

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/shared/dbaccess/sqlc/gen"
)

// TestConnectMigrateQuery proves the full pgx+goose+sqlc pipeline end-to-end
// against a real Postgres: migrate the schema, then run a typed query
// through it. The adapter only ever takes a Config — pointing it at a
// differently-hosted Postgres (see ../README.md) needs no code change here,
// just different Config values.
func TestConnectMigrateQuery(t *testing.T) {
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

	cfg := dbaccess.Config{
		Host:     host,
		Port:     port.Port(),
		User:     user,
		Password: password,
		Database: dbName,
		SSLMode:  "disable",
	}

	if err := dbaccess.Migrate(ctx, cfg.DSN(), dbaccess.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	pool, err := dbaccess.Connect(ctx, cfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	queries := sqlcgen.New(pool)

	id := pgtype.UUID{Bytes: [16]byte(uuid.New()), Valid: true}
	created, err := queries.CreateItem(ctx, sqlcgen.CreateItemParams{ID: id, Name: "first hive check"})
	if err != nil {
		t.Fatalf("create item: %v", err)
	}
	if created.Name != "first hive check" {
		t.Fatalf("created.Name = %q, want %q", created.Name, "first hive check")
	}

	got, err := queries.GetItem(ctx, id)
	if err != nil {
		t.Fatalf("get item: %v", err)
	}
	if got.ID != id {
		t.Fatalf("got.ID = %v, want %v", got.ID, id)
	}

	items, err := queries.ListItems(ctx)
	if err != nil {
		t.Fatalf("list items: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("len(items) = %d, want 1", len(items))
	}
}
