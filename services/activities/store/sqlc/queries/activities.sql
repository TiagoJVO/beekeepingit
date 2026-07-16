-- name: InsertActivity :one
-- Creates one activity row, org- and apiary-scoped (FR-TEN-2, FR-AC-1).
-- `attributes` is the caller's already-validated (api/types.go's
-- ValidateActivity) JSONB attribute bag for the selected `type` — this query
-- never re-validates it, matching the apiaries convention that the DB layer
-- trusts the API layer's validation pass. `journey_id` is nullable (D-21);
-- the actual auto-select/attribution UX is #46/M4, this column just exists
-- so no follow-up migration is needed when that lands.
INSERT INTO activities.activities
    (id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
RETURNING id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes,
          created_at, updated_at, recorded_at, deleted_at;

-- name: GetActivity :one
-- Org-scoped single-row read (never a client-supplied organization_id —
-- api/common.go's requireOrg pattern, mirrored from apiaries).
SELECT id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM activities.activities
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: ListActivitiesByApiary :many
-- Org- and apiary-scoped, live rows, newest first (FR-AC-5: apiary detail
-- page's activity list) — keyset-paginated on (occurred_at, id) since
-- occurred_at is not unique. Pass a null cursor pair for the first page.
SELECT id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM activities.activities
WHERE organization_id = $1
  AND apiary_id = $2
  AND deleted_at IS NULL
  AND (
        sqlc.narg('cursor_occurred_at')::date IS NULL
        OR occurred_at < sqlc.narg('cursor_occurred_at')::date
        OR (occurred_at = sqlc.narg('cursor_occurred_at')::date AND id < sqlc.narg('cursor_id')::uuid)
      )
ORDER BY occurred_at DESC, id DESC
LIMIT $3;

-- name: ListActivitiesByOrg :many
-- Org-wide, live rows, newest first (FR-AC-6: main activities page across
-- all apiaries) — same keyset shape as ListActivitiesByApiary above, minus
-- the apiary_id filter.
SELECT id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM activities.activities
WHERE organization_id = $1
  AND deleted_at IS NULL
  AND (
        sqlc.narg('cursor_occurred_at')::date IS NULL
        OR occurred_at < sqlc.narg('cursor_occurred_at')::date
        OR (occurred_at = sqlc.narg('cursor_occurred_at')::date AND id < sqlc.narg('cursor_id')::uuid)
      )
ORDER BY occurred_at DESC, id DESC
LIMIT $2;

-- name: InsertConflict :exec
-- The LWW safety net (sync.md §4.2) — kept as typed groundwork for #39's
-- sync-apply endpoint, mirroring apiaries.sync_conflict_log's own
-- InsertConflict query.
INSERT INTO activities.sync_conflict_log
    (id, organization_id, entity_type, entity_id, winning_payload, losing_payload, winner, actor_user_id, occurred_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: InsertAuditLog :exec
-- Append-only history row (history.md §3-§4, FR-HIS-1) — kept as typed
-- groundwork for #39's create path, mirroring apiaries.audit_log's own
-- InsertAuditLog query. changed_fields is null for create/delete.
INSERT INTO activities.audit_log
    (id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, changed_fields, change)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: ListAuditLog :many
-- The per-entity timeline read (FR-HIS-1) — not yet exposed via HTTP (no AC
-- in this milestone requires the view screens), kept as typed groundwork for
-- the entity-detail "history" screen, mirroring apiaries.ListAuditLog.
SELECT id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
FROM activities.audit_log
WHERE organization_id = $1 AND entity_type = $2 AND entity_id = $3
ORDER BY recorded_at, id;
