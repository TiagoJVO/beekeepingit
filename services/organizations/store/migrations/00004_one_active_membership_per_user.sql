-- +goose Up
-- Enforces the single-org-per-user invariant (C-1, api/organizations.go's
-- package doc) at the database level. idx_memberships_user_active (00001) is
-- a plain (non-unique) partial index — it only speeds up the active-
-- membership lookup, it does not stop two concurrent writers (two
-- createOrganization calls, or createOrganization racing an invitation
-- accept) from each passing the handler's pre-check and both committing an
-- 'active' row for the same user_id (a TOCTOU race: the check and the write
-- run in separate transactions, so a unique constraint is the only thing
-- that can close the window). This unique index makes that second commit
-- fail with a 23505 unique_violation instead, which the handlers now map to
-- the same 409 Conflict their pre-check already returns (see
-- api/organizations.go's isUniqueViolation).
CREATE UNIQUE INDEX idx_memberships_one_active_per_user
    ON organizations.memberships (user_id)
    WHERE status = 'active';

-- +goose Down
DROP INDEX IF EXISTS organizations.idx_memberships_one_active_per_user;
