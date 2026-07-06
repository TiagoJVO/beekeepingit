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
