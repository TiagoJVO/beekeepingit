-- +goose Up
-- organizations.audit_log.actor_scope (#470, FR-HIS-1, NFR-SEC-1, FR-TEN-2,
-- ADR-0021): distinguishes a history row written by an ordinary organization
-- member/admin from one written by a verified platform operator acting
-- outside their own membership (#466's platform-operator authorization
-- carve-out). ADR-0021 deliberately deferred persisting this distinction to
-- this story ("#470 ... persist a distinguishable, queryable record of
-- platform-path actions in history") rather than leaving it inferable only
-- by cross-referencing memberships later -- an operator acting on an org
-- they are NOT a member of leaves no membership row to cross-reference
-- against in the first place, so that inference is not even always possible.
--
-- NOT NULL DEFAULT 'member' keeps every pre-existing row, and every future
-- write from a call site this story doesn't touch (e.g. invitations.go's
-- invite/revoke/accept, which never run through the platform-operator path),
-- correctly and automatically attributed to the ordinary membership path
-- with no backfill needed -- 'member' is the true value for all of them.
-- The DEFAULT is a backward-compatibility safety net, not the attribution
-- mechanism itself: every writer records this value EXPLICITLY, in the same
-- INSERT as the rest of the row (api/audit.go's writeAuditLog gained a
-- mandatory actorScope parameter -- there is no optional/omittable path a
-- call site could silently skip), so the persisted value is always that
-- write's own, current authorization outcome, never a silently-inherited
-- stale default.
ALTER TABLE organizations.audit_log
    ADD COLUMN actor_scope TEXT NOT NULL DEFAULT 'member'
        CHECK (actor_scope IN ('member', 'platform_operator'));

-- +goose Down
ALTER TABLE organizations.audit_log DROP COLUMN IF EXISTS actor_scope;
