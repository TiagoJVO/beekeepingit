package dbaccess_test

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/shared/dbaccess/sqlc/gen"
)

// TestMigrate_InvalidDSN proves Migrate fails fast and with a wrapped,
// descriptive error when given a DSN goose/pgx cannot even parse — MEDIUM
// item #2: the only prior coverage of Migrate was the happy path inside
// TestConnectMigrateQuery. No Postgres instance is needed here: pgx's stdlib
// driver parses the DSN lazily on first use (not at sql.Open), and that
// parse failure surfaces synchronously, before any network call.
func TestMigrate_InvalidDSN(t *testing.T) {
	err := dbaccess.Migrate(context.Background(), "not-a-valid-dsn :: at all", dbaccess.MigrationsFS())
	if err == nil {
		t.Fatal("Migrate() error = nil, want a non-nil error for an unparseable DSN")
	}
	if !strings.Contains(err.Error(), "dbaccess:") {
		t.Errorf("Migrate() error = %q, want it wrapped with a dbaccess: prefix", err.Error())
	}
}

// TestMigrate_ConnectionFailure proves Migrate also fails (rather than
// hanging or panicking) when the DSN parses fine but the target is
// unreachable — the other half of MEDIUM item #2's "not just the happy
// path" ask, distinct from the parse-failure case above. connect_timeout=1
// keeps this fast and deterministic without a real Postgres instance.
func TestMigrate_ConnectionFailure(t *testing.T) {
	err := dbaccess.Migrate(context.Background(), "postgres://u:p@127.0.0.1:1/d?sslmode=disable&connect_timeout=1", dbaccess.MigrationsFS())
	if err == nil {
		t.Fatal("Migrate() error = nil, want a non-nil error for an unreachable host")
	}
	if !strings.Contains(err.Error(), "dbaccess:") {
		t.Errorf("Migrate() error = %q, want it wrapped with a dbaccess: prefix", err.Error())
	}
}

// TestMigrate_HonoursContextDeadline proves the caller's deadline is what
// bounds a migration — the control #551 moved OFF the Job's
// activeDeadlineSeconds (which starts at Job creation and so charges image pull
// to the migration) and INTO the process, where it starts when the migration
// does. Each service's runMigrate applies MigrationTimeout to the context it
// passes here, so this is that arrangement's load-bearing half: if Migrate ever
// stopped propagating ctx, a stuck migration would have nothing left holding it
// but the Job's backstop, and #541's "a failed migration fails the deploy,
// promptly" property would quietly go with it.
//
// This is also the only part of #551 that CAN be tested here. The cold-pull race
// itself is unreproducible in CI: helm-e2e pre-imports every service image into
// k3d, so pull time there is always zero.
//
// The fake server accepts the connection and then says nothing, which is what
// makes the test deterministic: pgx blocks in the startup handshake, so only the
// deadline can end the call. An unroutable address would depend on the host's
// firewall to hang rather than refuse.
func TestMigrate_HonoursContextDeadline(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	var mu sync.Mutex
	var accepted []net.Conn
	t.Cleanup(func() {
		mu.Lock()
		defer mu.Unlock()
		for _, conn := range accepted {
			_ = conn.Close()
		}
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			// Held open, never answered.
			mu.Lock()
			accepted = append(accepted, conn)
			mu.Unlock()
		}
	}()

	dsn := "postgres://u:p@" + listener.Addr().String() + "/d?sslmode=disable"

	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()

	start := time.Now()
	err = dbaccess.Migrate(ctx, dsn, dbaccess.MigrationsFS())
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Migrate() error = nil, want a non-nil error once the context deadline has passed")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Migrate() error = %v, want an error wrapping context.DeadlineExceeded", err)
	}
	// Generous relative to the 250ms deadline: the assertion is "the deadline
	// ended it", not a latency budget.
	if elapsed > 30*time.Second {
		t.Errorf("Migrate() returned after %s, want it to return when its context deadline passed", elapsed)
	}
}

// TestMigrationTimeout_LeavesRoomUnderTheJobBackstop guards the coupling that
// makes the split in #551 work. charts/services/templates/migrate-job.yaml
// retries the migration (backoffLimit: 2, so three attempts) under an
// activeDeadlineSeconds backstop of 900s. The backstop is only allowed to catch
// a pod that never RAN — if attempts x MigrationTimeout could reach it, the pod
// deadline would be back to deciding migrations, which is the bug.
//
// The two Job numbers are mirrored here by hand, since the chart is outside this
// module. That makes this a one-way guard, and deliberately the dangerous
// direction: it catches MigrationTimeout being raised without anyone thinking
// about the backstop, which is the change someone reaches for when a deploy
// feels slow. Editing the chart still needs a look at this test.
func TestMigrationTimeout_LeavesRoomUnderTheJobBackstop(t *testing.T) {
	const (
		attempts    = 3                 // backoffLimit: 2
		jobBackstop = 900 * time.Second // activeDeadlineSeconds
	)
	if worst := attempts * dbaccess.MigrationTimeout; worst >= jobBackstop {
		t.Errorf("%d attempts x MigrationTimeout (%s) = %s, which reaches the Job's %s backstop; "+
			"lower MigrationTimeout or raise activeDeadlineSeconds in charts/services/templates/migrate-job.yaml",
			attempts, dbaccess.MigrationTimeout, worst, jobBackstop)
	}
}

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
