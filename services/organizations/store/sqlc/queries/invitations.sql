-- name: CreateInvitation :one
-- Invites an email address to join organization_id (admin-only, FR-ONB-3).
-- The partial unique index (organization_id, lower(email)) WHERE status =
-- 'pending' rejects a second pending invite to the same address with a
-- unique_violation, which api/invitations.go maps to 409.
--
-- delivery_status starts at its 'pending' DEFAULT and is NOT set here: the row
-- must commit before the email is attempted (#641), so "created but not yet
-- sent" is a real, observable state for the duration of one send. The handler
-- claims the attempt with ClaimInvitationDeliverySlot in this same transaction
-- (#854 -- the attempt is charged before the mail leaves, never after) and
-- follows up with RecordInvitationDeliveryOutcome once the send has finished.
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

-- name: ClaimInvitationDeliverySlot :one
-- Claims ONE outbound-email attempt for an invitation, atomically (#854,
-- NFR-SEC-1). This single conditional UPDATE *is* the rate limit: it charges
-- the attempt and restarts the cooldown clock in the same statement that
-- checks them, so there is no window between reading the limits and acting on
-- them.
--
-- Zero rows means the attempt was REFUSED — the invitation is no longer
-- pending, its lifetime cap is spent, or it is still inside its cooldown — and
-- the caller must not open an SMTP conversation. One row means the slot is the
-- caller's and the returned row already reflects it.
--
-- It also resets delivery_status to 'pending' and clears delivery_error, so the
-- row reads "an attempt is in flight" for the duration of the send instead of
-- still advertising the PREVIOUS attempt's outcome beside an already-incremented
-- counter. If the outcome write is then lost, the admin sees an unknown result
-- rather than a stale one -- the honest state, and the same reasoning as #641's
-- "the screen must not say something that is not true".
--
-- Called by BOTH send paths: right after CreateInvitation inside the create
-- transaction, and at the top of a resend. Before #854 the resend path read
-- these two columns on the pool and let MarkInvitationDelivery increment them
-- after the send, which is a read-then-act pair in two directions at once:
-- concurrent resends of one invitation all saw the same pre-attempt state, and
-- an outcome write that failed left the attempt uncharged although the mail had
-- gone out (bookkeeping that failed OPEN).
--
-- Scoped by (id, organization_id) like every other write in this file
-- (ADR-0002).
UPDATE organizations.invitations
SET delivery_attempts = delivery_attempts + 1,
    last_delivery_at  = sqlc.arg(attempted_at),
    delivery_status   = 'pending',
    delivery_error    = ''
WHERE id = $1
  AND organization_id = $2
  AND status = 'pending'
  AND delivery_attempts < sqlc.arg(max_attempts)
  AND (last_delivery_at IS NULL OR last_delivery_at <= sqlc.arg(cooldown_cutoff))
RETURNING id, organization_id, email, role, status, delivery_status, delivery_error,
          delivery_attempts, last_delivery_at, invited_by, created_at, updated_at;

-- name: RecordInvitationDeliveryOutcome :one
-- Records what ONE outbound-email attempt DID (#641, FR-ONB-3), after
-- ClaimInvitationDeliverySlot has already charged the attempt and stamped
-- last_delivery_at. Outcome only: neither delivery_attempts nor
-- last_delivery_at is touched here, so losing this write costs the admin an
-- accurate status line — never a spent attempt or a cooldown (#854).
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
    delivery_error    = sqlc.arg(delivery_error)
WHERE id = $1 AND organization_id = $2
RETURNING id, organization_id, email, role, status, delivery_status, delivery_error,
          delivery_attempts, last_delivery_at, invited_by, created_at, updated_at;

-- name: CountInvitationDeliveryBudgetSince :one
-- The organization's outbound-mail budget for one rolling window (#641
-- security review, extended to resends by #854): how many MESSAGES has this
-- organization caused since `since`? An org admin can otherwise point the
-- service's relay at an unbounded list of arbitrary addresses — a spam/abuse
-- amplifier wearing a legitimate admin's credentials, and a reputation risk for
-- the sending domain (#417).
--
-- Sums ATTEMPTS, not rows. Counting rows (this query's first #854 shape) charged
-- an invitation once no matter how many messages it emitted, so an admin could
-- create 19 invitations and then resend each of them every minute forever — the
-- count never moved, and the real ceiling was ~10x the stated one. Summing
-- delivery_attempts makes every message cost exactly one slot in the ordinary
-- case, and the budget mean what the 429 says it means.
--
-- A row is in the window when it was CREATED there (its create-time send) or
-- last ATTEMPTED there (a resend), so creation and resend share one budget:
-- what is bounded is mail leaving on behalf of one organization per hour, not
-- the endpoint that triggered it. Counting only created_at — as this query did
-- before #854 — left resend outside the ceiling entirely, since it can target
-- any still-pending invitation of any age.
--
-- The approximation, stated plainly: resending an invitation created BEFORE the
-- window drags its whole attempt history into the sum, so it can cost up to
-- maxDeliveryAttempts slots for one message. That direction is deliberate — the
-- sum can never be lower than the messages actually sent in the window, so the
-- limit fails CLOSED — and the over-charge lands only on the rows that have
-- already generated the most mail, which have at most ten attempts in them ever.
-- An exact per-attempt ledger needs a new table, and a new table in this schema
-- joins the PowerSync publication (infra/helm .../cluster.yaml), so it is a
-- deliberate follow-up rather than smuggled in here.
--
-- Counts EVERY invitation in the window regardless of status or delivery
-- outcome: revoking or failing to deliver must not reset the budget, or the
-- limit is trivially bypassed by revoking each invite after creating it.
-- organization_id is the leading column of
-- invitations_organization_id_created_at_idx (migration 00008), which narrows
-- this to one tenant's own (small) set of rows before either date is examined.
SELECT coalesce(sum(delivery_attempts), 0)::bigint
FROM organizations.invitations
WHERE organization_id = $1
  AND (created_at >= sqlc.arg(since) OR last_delivery_at >= sqlc.arg(since));
