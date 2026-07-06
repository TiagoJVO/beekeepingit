package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
)

// Seed inserts the dev/CI org and the test user's active admin membership so
// the walking-skeleton resolve path (user → active membership → org + role,
// §4.2) succeeds without EPIC-01 onboarding. Idempotent and only ever called
// when SEED_DEV_DATA=true — never in production.
func Seed(ctx context.Context, pool *pgxpool.Pool) error {
	if _, err := pool.Exec(ctx, `
		INSERT INTO organizations.organizations (id, name, created_by)
		VALUES ($1, $2, $3)
		ON CONFLICT (id) DO NOTHING`,
		devseed.OrganizationID, devseed.OrganizationName, devseed.UserID); err != nil {
		return fmt.Errorf("organizations: seed org: %w", err)
	}

	if _, err := pool.Exec(ctx, `
		INSERT INTO organizations.memberships (id, organization_id, user_id, role, status)
		VALUES ($1, $2, $3, $4, 'active')
		ON CONFLICT (organization_id, user_id) DO NOTHING`,
		devseed.MembershipID, devseed.OrganizationID, devseed.UserID, devseed.MembershipRole); err != nil {
		return fmt.Errorf("organizations: seed membership: %w", err)
	}
	return nil
}
