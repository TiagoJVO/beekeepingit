-- +goose Up
-- #468 (cross-organization membership lookup for support, FR-TEN-2, D-7)
-- introduces the first query that reads a user's memberships across EVERY
-- organization, including 'removed' ones -- unlike idx_memberships_user_active
-- (00001), which only covers status = 'active', or
-- idx_memberships_one_active_per_user (00004), which is a uniqueness
-- constraint, not a lookup aid. A plain (non-partial) index on user_id backs
-- that new access pattern, since the single-org-per-user invariant (C-1)
-- means most users have only one 'active' row but can
-- accumulate several 'removed' ones across their history, none of which the
-- existing partial indexes help serve. See ListMembershipsByUser
-- (store/sqlc/queries/memberships.sql).
CREATE INDEX idx_memberships_user_id
    ON organizations.memberships (user_id);

-- +goose Down
DROP INDEX IF EXISTS organizations.idx_memberships_user_id;
