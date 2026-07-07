-- name: GetActiveMembershipByUser :one
-- The auth middleware's resolve step (§4.2): the user's active membership
-- gives the request its organization_id + role. v1 is single-org (C-1); if a
-- user ever has several active memberships, the earliest is chosen.
SELECT id, organization_id, user_id, role, status
FROM organizations.memberships
WHERE user_id = $1 AND status = 'active'
ORDER BY created_at
LIMIT 1;

-- name: GetOrganization :one
SELECT id, name, address, created_by, created_at, updated_at
FROM organizations.organizations
WHERE id = $1;

-- name: CreateMembership :one
-- Inserts the org creator's active admin membership (D-3). Called in the same
-- DB transaction as CreateOrganization (api/organizations.go).
INSERT INTO organizations.memberships (id, organization_id, user_id, role, status)
VALUES ($1, $2, $3, 'admin', 'active')
RETURNING id, organization_id, user_id, role, status, created_at, updated_at;

-- name: CreateMembershipWithRole :one
-- Inserts an active membership at the given role — the accept-invitation
-- path (#27, FR-ONB-3), where the role comes from the invitation rather
-- than always being 'admin'. Called in the same DB transaction as
-- AcceptInvitation (api/invitations.go acceptPendingInvitation), same D-3
-- atomicity pattern as CreateOrganization+CreateMembership.
INSERT INTO organizations.memberships (id, organization_id, user_id, role, status)
VALUES ($1, $2, $3, $4, 'active')
RETURNING id, organization_id, user_id, role, status, created_at, updated_at;

-- name: ListMembers :many
-- Keyset-paginated by id — the admin-facing member list (NFR-ROL-1, #27 AC:
-- "membership is enforced for data access" / management surface). Excludes
-- 'removed' memberships (not built yet — #27 explicitly defers member
-- removal — but the CHECK constraint already allows the value and the
-- Member.status schema enum lists it, so this filter is future-proofed).
SELECT id, organization_id, user_id, role, status, created_at, updated_at
FROM organizations.memberships
WHERE organization_id = $1
  AND status != 'removed'
  AND (sqlc.narg('cursor')::uuid IS NULL OR id < sqlc.narg('cursor')::uuid)
ORDER BY id DESC
LIMIT $2;
