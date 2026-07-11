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
