package dbaccess

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Connect builds a pgx connection pool from cfg and fails fast: it pings the
// database before returning, so misconfiguration surfaces immediately
// rather than on the first query.
func Connect(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}

	pool, err := pgxpool.New(ctx, cfg.DSN())
	if err != nil {
		return nil, fmt.Errorf("dbaccess: new pool: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("dbaccess: ping: %w", err)
	}

	return pool, nil
}
