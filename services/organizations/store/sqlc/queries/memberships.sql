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

-- name: GetActiveMembership :one
-- The target member of a management action (#290): one org's active membership
-- for a given user. Org-scoped (organization_id = $1) so a cross-org caller can
-- never address another org's membership (ADR-0002). pgx.ErrNoRows means "no
-- such active member in this org" — the handler maps it to 404 (already removed,
-- never a member, or a different org's user).
SELECT id, organization_id, user_id, role, status, created_at, updated_at
FROM organizations.memberships
WHERE organization_id = $1 AND user_id = $2 AND status = 'active';

-- name: LockOrganizationForUpdate :one
-- The last-admin guard's single per-org serialization point (#290, D-3): row-lock
-- the organization itself FOR UPDATE at the top of every remove/change-role
-- transaction. All such writes on one org therefore serialize on this single row,
-- so the CountActiveAdmins check below runs against a stable admin set that no
-- concurrent demote/remove/promote can change before this transaction commits —
-- closing the TOCTOU race that would otherwise let two concurrent demotions each
-- see "two admins" and together leave the org with zero. Locking the org row
-- (rather than the admin membership rows) also avoids spuriously blocking on / by
-- an unrelated promotion. The caller is already an admin of this exact org
-- (requireOrgAdmin), so the row always exists.
SELECT id
FROM organizations.organizations
WHERE id = $1
FOR UPDATE;

-- name: CountActiveAdmins :one
-- Count an org's active admins for the last-admin guard (#290, D-3). Only ever
-- called after LockOrganizationForUpdate has serialized this org's lifecycle
-- writes, so the count can't change under us before the transaction commits.
SELECT count(*)
FROM organizations.memberships
WHERE organization_id = $1 AND role = 'admin' AND status = 'active';

-- name: UpdateMembershipRole :one
-- Changes an active member's role within the fixed admin/user model (#290,
-- NFR-ROL-1/2, auth.md §5.3). Org-scoped; updated_at is bumped explicitly (no
-- ON UPDATE trigger on this table). Called in the same transaction as its
-- #165 audit row, after the last-admin guard has run.
UPDATE organizations.memberships
SET role = $3, updated_at = now()
WHERE organization_id = $1 AND user_id = $2 AND status = 'active'
RETURNING id, organization_id, user_id, role, status, created_at, updated_at;

-- name: RemoveMembership :one
-- Soft-removes an active member (#290, FR-TEN-2): status active -> removed, so
-- the user immediately stops resolving to this org on their next request
-- (GetActiveMembershipByUser filters status = 'active') and frees the
-- one-active-membership-per-user slot (idx_memberships_one_active_per_user,
-- 00004). The row is kept (not hard-deleted) so its history/audit trail and
-- UNIQUE(organization_id, user_id) identity survive. Org-scoped; updated_at
-- bumped explicitly. Same-transaction #165 audit row as the other writes.
UPDATE organizations.memberships
SET status = 'removed', updated_at = now()
WHERE organization_id = $1 AND user_id = $2 AND status = 'active'
RETURNING id, organization_id, user_id, role, status, created_at, updated_at;

-- name: ListMembershipsByUser :many
-- The #468 cross-organization membership lookup (FR-TEN-2, D-7, NFR-SEC-1):
-- every membership row for ONE user_id, across ALL organizations, joined with
-- each organization's name -- the only query in this service that reads
-- memberships without an organization_id already in scope, by design (the
-- support question this backs is "which org(s) does this person belong to").
-- Unlike ListMembers, this does NOT filter out status = 'removed': a
-- support operator needs the full picture, including orgs the person was
-- later removed from, not just their current one (the Member.status schema
-- enum already includes it). Keyset-paginated by membership id, newest
-- first (mirrors ListInvitations' newest-first convention -- the most
-- recent org relationship is the one a support case most likely cares
-- about). idx_memberships_user_id (migration 00005) backs the WHERE
-- clause.
SELECT m.id, m.organization_id, o.name AS organization_name, m.role, m.status
FROM organizations.memberships m
JOIN organizations.organizations o ON o.id = m.organization_id
WHERE m.user_id = sqlc.arg('user_id')
  AND (sqlc.narg('cursor')::uuid IS NULL OR m.id < sqlc.narg('cursor')::uuid)
ORDER BY m.id DESC
LIMIT sqlc.arg('limit');

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
