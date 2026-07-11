package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

// Seed inserts the dev/CI test user (devseed.OidcSub → devseed.UserID) so
// the walking-skeleton login path resolves to a real identity.users row
// without EPIC-01 onboarding (walking-skeleton.md §4.5). It is idempotent
// (ON CONFLICT DO NOTHING) and only ever called when SEED_DEV_DATA=true —
// never in production.
func Seed(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		INSERT INTO identity.users (id, oidc_sub, name, email, locale)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (oidc_sub) DO NOTHING`,
		devseed.UserID, devseed.OidcSub, devseed.UserName, devseed.UserEmail, devseed.UserLocale)
	if err != nil {
		return fmt.Errorf("identity: seed dev user: %w", err)
	}
	return nil
}
