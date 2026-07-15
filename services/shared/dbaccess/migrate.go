package dbaccess

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"

	_ "github.com/jackc/pgx/v5/stdlib" // registers the "pgx" database/sql driver
	"github.com/pressly/goose/v3"
)

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
