-- +goose Up
-- #468 (organizations' platform cross-organization membership-lookup support
-- tool) introduces the first query that looks up identity.users BY EMAIL
-- (GetUserByEmail, store/sqlc/queries/users.sql) rather than by the uniquely-
-- indexed oidc_sub (00001/00002). A functional index on lower(email) backs
-- that new access pattern's case-insensitive match -- without it, every
-- lookup is a full sequential scan, mirroring the analogous fix organizations'
-- own migration 00005 (idx_memberships_user_id) makes for its new
-- ListMembershipsByUser query. Excludes the empty-string default
-- (UpsertUserOnFirstSeen's placeholder for an incomplete profile) so the
-- index stays useful -- it would otherwise carry one enormous, unselective
-- entry for every never-completed profile.
CREATE INDEX idx_users_email_lower
    ON identity.users (lower(email))
    WHERE email <> '';

-- +goose Down
DROP INDEX IF EXISTS identity.idx_users_email_lower;
