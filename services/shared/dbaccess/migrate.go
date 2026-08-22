package dbaccess

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
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

	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations)
	if err != nil {
		return fmt.Errorf("dbaccess: new goose provider: %w", err)
	}

	if _, err := provider.Up(ctx); err != nil {
		return fmt.Errorf("dbaccess: apply migrations: %w", err)
	}
	return nil
}
