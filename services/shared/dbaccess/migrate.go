package dbaccess

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib" // registers the "pgx" database/sql driver
	"github.com/pressly/goose/v3"
)

// MigrationTimeout bounds one deploy-time migration run. Each service's
// runMigrate applies it to the context it hands to Migrate.
//
// WHY THE BOUND LIVES IN THE PROCESS (#551). The migrate Job used to be bounded
// only by its `activeDeadlineSeconds: 300`. Kubernetes starts that clock when
// the Job is created, so it pays for scheduling and image pull as well as the
// migration — and on the first deploy of a new version every Deployment in the
// release is rolling at once, so the node is pulling the whole image set while
// this Job queues behind it. On staging's v0.0.1-rc9 that was enough:
// `activities-migrate` died with DeadlineExceeded and failed the Helm release,
// Flux retried, and the same job passed in 36s — while `apiaries-migrate`, same
// SQL with the image already cached, took 6s. None of the 300s was ever spent
// migrating.
//
// Kubernetes offers no way to exclude pull time from that clock, so the fix is
// not a larger number — it is to bound the thing we actually mean to bound.
// This deadline starts when the migration starts, so a cold deploy pays for its
// pull outside the budget, while a migration that hangs still fails fast and
// still fails the release. That last property is not incidental: #541 made a
// failed migration a loud, deploy-blocking event precisely because the previous
// design let one hide behind a healthy older ReplicaSet for 25 days.
//
// Two minutes is roughly twenty times the slowest migration this codebase has
// produced (they run in seconds). Raise it deliberately, for a specific
// migration that genuinely needs longer — it is not a knob to widen when a
// deploy feels slow, and widening it no longer buys tolerance for a slow pull,
// which is what the old number was really being asked for.
//
// The deadline reaches the server, not just the Go code: pgx forwards
// cancellation as a Postgres cancel request, so a migration stuck waiting on a
// lock it will never get — the realistic shape of "stuck" here — is aborted
// rather than left to be killed with the pod.
const MigrationTimeout = 2 * time.Minute

// Migrate applies all pending "up" migrations found in migrations (an
// os.DirFS or embed.FS rooted at a migrations directory) against dsn.
//
// It goes through database/sql (not pgxpool) because that's what goose's
// Provider expects; the app's own queries still go through the pgxpool pool
// returned by Connect.
func Migrate(ctx context.Context, dsn string, migrations fs.FS) error {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return fmt.Errorf("dbaccess: open migration connection: %w", err)
	}
	defer func() { _ = db.Close() }()

	// WAIT FOR POSTGRES TO ANSWER BEFORE MIGRATING (#551), and only for that.
	//
	// At hook-weight 2 Postgres is usually up, but "usually" is not always:
	// helm-e2e caught the migrate Job racing a CNPG instance that was still
	// starting — three attempts at 23:46:39/:49/23:47:09 against a server whose
	// instance manager only began at 23:46:24, each dying instantly with
	// `dial tcp ...:5432: connect: connection refused`.
	//
	// That race was previously absorbed by accident: `backoffLimit: 10` on the
	// Job meant ten pod restarts, which happened to outlast Postgres' startup.
	// Cutting the limit so a BROKEN migration reports quickly (also #551) removed
	// the tolerance along with the waste, because a Job retry cannot tell the two
	// apart — every failure costs the same budget whether the SQL is wrong or the
	// server merely isn't listening yet.
	//
	// Waiting here separates them exactly. An unreachable server is retried until
	// the caller's deadline (MigrationTimeout); a migration that fails once
	// connected is NOT retried at all and surfaces on the first attempt, which is
	// the fast-fail property #541 made load-bearing. Same reasoning as the
	// exit-code split in charts/postgres' table-grants Job — retry only what is
	// worth retrying.
	if err := waitForDB(ctx, db); err != nil {
		return err
	}

	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations)
	if err != nil {
		return fmt.Errorf("dbaccess: new goose provider: %w", err)
	}

	if _, err := provider.Up(ctx); err != nil {
		return fmt.Errorf("dbaccess: apply migrations: %w", err)
	}
	return nil
}

// dbProbeInterval is how often waitForDB re-probes a server that is not yet
// listening. Short enough that a migration is not needlessly delayed once
// Postgres comes up, long enough not to hammer a starting server.
const dbProbeInterval = 2 * time.Second

// waitForDB blocks until the server answers or ctx expires, and reports the
// LAST connection error rather than a bare deadline — "connection refused" is
// what tells an operator the server was not listening, whereas "context
// deadline exceeded" alone would leave them guessing.
//
// Deliberately only used by Migrate, not by Connect: a serving process that
// cannot reach Postgres should fail its readiness probe and be restarted by
// Kubernetes, which is a better place to wait than inside a request path.
func waitForDB(ctx context.Context, db *sql.DB) error {
	lastErr := db.PingContext(ctx)
	if lastErr == nil {
		return nil
	}

	// TWO THINGS ARE DELIBERATELY NOT RETRIED, both learned by breaking them:
	//
	// 1. A failure that is not a dial failure. An unparseable DSN, a rejected
	//    password, a missing database — none of those get better by asking
	//    again, and retrying them for two minutes turns a clear error into a
	//    timeout, which is the reporting regression this whole issue is about.
	//    Only *net.OpError (the shape of "connection refused" / "no such host")
	//    means the server might simply not be listening yet.
	// 2. A context with no deadline. Callers that pass context.Background()
	//    have not asked to wait for anything, and looping on them would hang
	//    forever rather than return — which is exactly what an earlier version
	//    of this function did to TestMigrate_InvalidDSN.
	var opErr *net.OpError
	if !errors.As(lastErr, &opErr) {
		return fmt.Errorf("dbaccess: connect for migration: %w", lastErr)
	}
	deadline, ok := ctx.Deadline()
	if !ok {
		return fmt.Errorf("dbaccess: connect for migration: %w", lastErr)
	}

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("dbaccess: database did not become reachable before the deadline (%s): %w",
				time.Until(deadline).Round(time.Second), lastErr)
		case <-time.After(dbProbeInterval):
		}

		lastErr = db.PingContext(ctx)
		if lastErr == nil {
			return nil
		}
		// Stop as soon as the failure stops looking transient — the server is
		// answering now, and whatever it is saying is the real error.
		if !errors.As(lastErr, &opErr) {
			return fmt.Errorf("dbaccess: connect for migration: %w", lastErr)
		}
	}
}
