-- name: CreateInvitation :one
-- Invites an email address to join organization_id (admin-only, FR-ONB-3).
-- The partial unique index (organization_id, lower(email)) WHERE status =
-- 'pending' rejects a second pending invite to the same address with a
-- unique_violation, which api/invitations.go maps to 409.
INSERT INTO organizations.invitations (id, organization_id, email, role, invited_by)
VALUES ($1, $2, lower(sqlc.arg(email)), $3, $4)
RETURNING id, organization_id, email, role, status, invited_by, created_at, updated_at;

-- name: ListInvitations :many
-- Keyset-paginated by id, newest first (most-actionable invites surface
-- first for the admin) — same sqlc.narg nullable-cursor idiom as apiaries'
-- ListApiaries, just descending instead of ascending.
SELECT id, organization_id, email, role, status, invited_by, created_at, updated_at
FROM organizations.invitations
WHERE organization_id = $1
  AND (sqlc.narg('cursor')::uuid IS NULL OR id < sqlc.narg('cursor')::uuid)
ORDER BY id DESC
LIMIT $2;

-- name: GetInvitation :one
SELECT id, organization_id, email, role, status, invited_by, created_at, updated_at
FROM organizations.invitations
WHERE id = $1 AND organization_id = $2;

-- name: RevokeInvitation :one
-- Only a still-pending invitation can be revoked (admin-only). Returns the
-- updated row so the handler can distinguish "already resolved" (0 rows,
-- because the WHERE status='pending' guard excluded it) from "not found".
UPDATE organizations.invitations
SET status = 'revoked', updated_at = now()
WHERE id = $1 AND organization_id = $2 AND status = 'pending'
RETURNING id, organization_id, email, role, status, invited_by, created_at, updated_at;

-- name: GetPendingInvitationByEmail :one
-- The accept-on-login lookup (FR-ONB-3 AC 2): does this verified profile
-- email have a pending invitation anywhere? v1 is single-org-per-user (C-1),
-- so the first (oldest) pending invite wins if more than one org somehow
-- invited the same address.
SELECT id, organization_id, email, role, status, invited_by, created_at, updated_at
FROM organizations.invitations
WHERE lower(email) = lower(sqlc.arg(email)) AND status = 'pending'
ORDER BY created_at
LIMIT 1;

-- name: AcceptInvitation :one
-- Marks the invitation accepted. Called in the same transaction as the
-- membership insert (api/invitations.go acceptPendingInvitation) so an
-- invitation is never left pending after its membership exists, or vice
-- versa (mirrors CreateOrganization+CreateMembership's D-3 atomicity).
UPDATE organizations.invitations
SET status = 'accepted', updated_at = now()
WHERE id = $1 AND status = 'pending'
RETURNING id, organization_id, email, role, status, invited_by, created_at, updated_at;
