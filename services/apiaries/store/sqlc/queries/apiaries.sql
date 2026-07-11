-- name: ListApiaries :many
-- Org-scoped, live-row keyset page ordered by id (UUIDv7 ⇒ chronological).
-- Pass a null cursor for the first page; fetch limit+1 to detect a next page.
SELECT id, organization_id, name, hive_count, created_at, updated_at
FROM apiaries.apiaries
WHERE organization_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('cursor')::uuid IS NULL OR id > sqlc.narg('cursor')::uuid)
ORDER BY id
LIMIT $2;

-- name: GetApiary :one
SELECT id, organization_id, name, hive_count, created_at, updated_at
FROM apiaries.apiaries
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: GetApiaryForUpdate :one
-- Locks the row (or reports its absence) for the LWW apply transaction.
SELECT id, organization_id, name, hive_count, created_at, updated_at, deleted_at
FROM apiaries.apiaries
WHERE organization_id = $1 AND id = $2
FOR UPDATE;

-- name: InsertApiary :exec
INSERT INTO apiaries.apiaries (id, organization_id, name, hive_count, updated_at, deleted_at)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: UpdateApiary :exec
UPDATE apiaries.apiaries
SET name = $3, hive_count = $4, updated_at = $5, deleted_at = $6, recorded_at = now()
WHERE organization_id = $1 AND id = $2;

-- name: InsertConflict :exec
INSERT INTO apiaries.sync_conflict_log
    (id, organization_id, entity_type, entity_id, winning_payload, losing_payload, winner, actor_user_id, occurred_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: InsertAuditLog :exec
-- Append-only history row (history.md §3-§4, #59): one row per applied
-- create/update/delete, written in the same local transaction as the domain
-- write. changed_fields is null for create/delete (only update carries it).
INSERT INTO apiaries.audit_log
    (id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, changed_fields, change)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: ListAuditLog :many
-- The per-entity timeline read (FR-HIS-1, history.md §8): every history row
-- for one entity, oldest first. Not yet exposed via HTTP (no AC in this
-- milestone requires the view screens, history.md §8/§10) — kept as typed
-- groundwork for the entity-detail "history" screen.
SELECT id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
FROM apiaries.audit_log
WHERE organization_id = $1 AND entity_type = $2 AND entity_id = $3
ORDER BY recorded_at, id;

-- name: ListEntityTimeline :many
-- The combined per-entity timeline (#61 AC, history.md §6): UNIONs
-- apiaries.audit_log (applied create/update/delete rows, event_kind =
-- change_type) with apiaries.sync_conflict_log (LWW-loss rows, event_kind
-- hardcoded 'superseded' — mirrors history.EventSuperseded — history.md §6
-- "LWW losers... surfaced as a superseded timeline event, not silently
-- overwritten"), ordered chronologically. change carries the audit delta for
-- audit_log rows and the {winning_payload, losing_payload, winner} conflict
-- payload for sync_conflict_log rows — the two tables' change shapes differ
-- by design (§3 vs §4.2), so callers branch on event_kind to interpret it.
-- Like ListAuditLog, not yet exposed via HTTP — typed groundwork for the
-- entity-detail "history" screen (history.md §8/§10).
SELECT timeline.id, timeline.organization_id, timeline.entity_type, timeline.entity_id,
       timeline.event_kind, timeline.actor_user_id, timeline.occurred_at, timeline.recorded_at,
       timeline.changed_fields, timeline.change
FROM (
    SELECT al.id, al.organization_id, al.entity_type, al.entity_id, al.change_type AS event_kind,
           al.actor_user_id, al.occurred_at, al.recorded_at, al.changed_fields, al.change
    FROM apiaries.audit_log al
    WHERE al.organization_id = $1 AND al.entity_type = $2 AND al.entity_id = $3

    UNION ALL

    SELECT scl.id, scl.organization_id, scl.entity_type, scl.entity_id, 'superseded' AS event_kind,
           scl.actor_user_id, scl.occurred_at, scl.recorded_at, NULL::text[] AS changed_fields,
           jsonb_build_object('winning_payload', scl.winning_payload, 'losing_payload', scl.losing_payload, 'winner', scl.winner) AS change
    FROM apiaries.sync_conflict_log scl
    WHERE scl.organization_id = $1 AND scl.entity_type = $2 AND scl.entity_id = $3
) timeline
ORDER BY timeline.recorded_at, timeline.id;
