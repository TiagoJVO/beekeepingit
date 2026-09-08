-- name: CreateInvitation :one
-- Invites an email address to join organization_id (admin-only, FR-ONB-3).
-- The partial unique index (organization_id, lower(email)) WHERE status =
-- 'pending' rejects a second pending invite to the same address with a
-- unique_violation, which api/invitations.go maps to 409.
--
-- delivery_status starts at its 'pending' DEFAULT and is NOT set here: the row
-- must commit before the email is attempted (#641), so "created but not yet
-- sent" is a real, observable state for the duration of one send. The handler
-- follows up with MarkInvitationDelivery.
INSERT INTO organizations.invitations (id, organization_id, email, role, invited_by)
VALUES ($1, $2, lower(sqlc.arg(email)), $3, $4)
RETURNING id, organization_id, email, role, status, delivery_status, delivery_error,
          delivery_attempts, last_delivery_at, invited_by, created_at, updated_at;

-- name: ListInvitations :many
-- Keyset-paginated by id, newest first (most-actionable invites surface
-- first for the admin) — same sqlc.narg nullable-cursor idiom as apiaries'
-- ListApiaries, just descending instead of ascending.
SELECT id, organization_id, email, role, status, delivery_status, delivery_error,
       delivery_attempts, last_delivery_at, invited_by, created_at, updated_at
FROM organizations.invitations
WHERE organization_id = $1
  AND (sqlc.narg('cursor')::uuid IS NULL OR id < sqlc.narg('cursor')::uuid)
ORDER BY id DESC
LIMIT $2;

-- name: GetInvitation :one
SELECT id, organization_id, email, role, status, delivery_status, delivery_error,
       delivery_attempts, last_delivery_at, invited_by, created_at, updated_at
FROM organizations.invitations
WHERE id = $1 AND organization_id = $2;

-- name: RevokeInvitation :one
-- Only a still-pending invitation can be revoked (admin-only). Returns the
-- updated row so the handler can distinguish "already resolved" (0 rows,
-- because the WHERE status='pending' guard excluded it) from "not found".
UPDATE organizations.invitations
SET status = 'revoked', updated_at = now()
WHERE id = $1 AND organization_id = $2 AND status = 'pending'
RETURNING id, organization_id, email, role, status, delivery_status, delivery_error,
          delivery_attempts, last_delivery_at, invited_by, created_at, updated_at;

-- name: GetPendingInvitationByEmail :one
-- The accept-on-login lookup (FR-ONB-3 AC 2): does this verified profile
-- email have a pending invitation anywhere? v1 is single-org-per-user (C-1),
-- so the first (oldest) pending invite wins if more than one org somehow
-- invited the same address.
--
-- Deliberately NOT filtered on delivery_status (#641): an invitation whose
-- email failed to send is still a real invitation the admin made, and if the
-- invitee learns of it another way (the admin phones them) they must still be
-- able to join. Delivery state drives what the ADMIN sees, never who may
-- accept.
SELECT id, organization_id, email, role, status, delivery_status, delivery_error,
       delivery_attempts, last_delivery_at, invited_by, created_at, updated_at
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
RETURNING id, organization_id, email, role, status, delivery_status, delivery_error,
          delivery_attempts, last_delivery_at, invited_by, created_at, updated_at;

-- name: MarkInvitationDelivery :one
-- Records the outcome of ONE outbound-email attempt (#641, FR-ONB-3): the
-- initial send after CreateInvitation, or an admin-triggered resend.
-- delivery_attempts is incremented here rather than passed in, so two
-- concurrent attempts can never both write the same count.
--
-- `updated_at` is deliberately NOT touched: it is the invitation's LWW/ETag
-- version stamp for the domain row (data-model.md §4.3), and a delivery
-- retry is not a change to the invitation itself. last_delivery_at is the
-- delivery axis's own clock.
--
-- Scoped by (id, organization_id) like every other write in this file
-- (ADR-0002) — the handler has already asserted the caller is an admin of
-- exactly this org, and the scope here makes that structural rather than
-- merely conventional.
UPDATE organizations.invitations
SET delivery_status   = sqlc.arg(delivery_status),
    delivery_error    = sqlc.arg(delivery_error),
    delivery_attempts = delivery_attempts + 1,
    last_delivery_at  = sqlc.arg(last_delivery_at)
WHERE id = $1 AND organization_id = $2
RETURNING id, organization_id, email, role, status, delivery_status, delivery_error,
          delivery_attempts, last_delivery_at, invited_by, created_at, updated_at;

-- name: CountInvitationsCreatedSince :one
-- Rate-limit counter for POST .../invitations (#641 security review): how many
-- invitations has this organization created since `since`? An org admin can
-- otherwise point the service's relay at an unbounded list of arbitrary
-- addresses — a spam/abuse amplifier wearing a legitimate admin's credentials,
-- and a reputation risk for the sending domain (#417).
--
-- Counts EVERY invitation in the window regardless of status or delivery
-- outcome: revoking or failing to deliver must not reset the budget, or the
-- limit is trivially bypassed by revoking each invite after creating it.
-- Served by invitations_organization_id_created_at_idx (migration 00008).
SELECT count(*)
FROM organizations.invitations
WHERE organization_id = $1 AND created_at >= sqlc.arg(since);
