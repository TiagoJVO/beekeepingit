-- name: InsertJourney :one
-- Creates one journey row, org-scoped (FR-TEN-2, FR-JO-4). status defaults to
-- 'open' at the DB level; callers that need it explicit (idempotent-replay
-- comparisons) still pass it so this query never depends on the column
-- default alone.
INSERT INTO journeys.journeys
    (id, organization_id, name, main_activity_type, status, default_attributes, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING id, organization_id, name, main_activity_type, status, default_attributes,
          created_at, updated_at, recorded_at, deleted_at;

-- name: GetJourney :one
-- Org-scoped single-row read (never a client-supplied organization_id —
-- api/common.go's requireOrg pattern, mirrored from activities).
SELECT id, organization_id, name, main_activity_type, status, default_attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM journeys.journeys
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: GetJourneyForUpdate :one
-- Locks the row (or reports its absence, including a soft-deleted one) for
-- the REST update/delete transaction and the sync-apply LWW compare — no
-- deleted_at filter, callers explicitly check the returned row's deleted_at
-- (mirrors activities' GetActivityForUpdate).
SELECT id, organization_id, name, main_activity_type, status, default_attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM journeys.journeys
WHERE organization_id = $1 AND id = $2
FOR UPDATE;

-- name: ListJourneysByOrg :many
-- Org-wide, live rows, newest first (#45's minimal list screen; #47 adds
-- filters later) — keyset-paginated on (created_at, id) since created_at is
-- not unique. Pass a null cursor pair for the first page.
SELECT id, organization_id, name, main_activity_type, status, default_attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM journeys.journeys
WHERE organization_id = $1
  AND deleted_at IS NULL
  AND (
        sqlc.narg('cursor_created_at')::timestamptz IS NULL
        OR created_at < sqlc.narg('cursor_created_at')::timestamptz
        OR (created_at = sqlc.narg('cursor_created_at')::timestamptz AND id < sqlc.narg('cursor_id')::uuid)
      )
ORDER BY created_at DESC, id DESC
LIMIT $2;

-- name: UpdateJourney :one
-- REST update (PATCH /v1/journeys/{id}): the caller computes the full desired
-- row first (matching sync.go's mergeJourneyOp pattern), so this always sets
-- every mutable column, INCLUDING default_attributes (absent-on-PATCH keeps
-- the caller's already-loaded value — write.go's updateJourney computes it,
-- matching status's optionality convention).
UPDATE journeys.journeys
SET name = $3, main_activity_type = $4, status = $5, default_attributes = $6, updated_at = $7, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL
RETURNING id, organization_id, name, main_activity_type, status, default_attributes,
          created_at, updated_at, recorded_at, deleted_at;

-- name: UpdateJourneySync :exec
-- Sync-apply put/patch/delete: sets every mutable column, INCLUDING
-- deleted_at (a tombstone is just another LWW-compared field, mirrors
-- activities' UpdateActivitySync) and default_attributes — the caller
-- (applyJourneyOp's mergeJourneyOp) computes the full desired row first.
UPDATE journeys.journeys
SET name = $3, main_activity_type = $4, status = $5, default_attributes = $6, updated_at = $7, deleted_at = $8, recorded_at = now()
WHERE organization_id = $1 AND id = $2;

-- name: SoftDeleteJourney :execrows
-- REST delete (DELETE /v1/journeys/{id}): tombstone, matching the sync path's
-- deleted_at convention so the delete propagates to devices (FR-OF-1) — the
-- PowerSync Sync Rules already filter deleted_at IS NULL. :execrows so the
-- caller can distinguish "already gone" (0 rows) from success without a
-- separate SELECT, mirroring activities' SoftDeleteActivity. The journey's
-- plan items are deliberately left in place (soft-deleted-parent, inert),
-- mirroring apiaries' own "delete apiary, leave its counter rows" convention.
UPDATE journeys.journeys
SET deleted_at = $3, updated_at = $3, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: InsertJourneyPlanItem :one
-- Adds one apiary to a journey's plan (FR-JO-4). apiary_id is a
-- CROSS-SERVICE reference already verified against the apiaries service
-- (api/apiaries_client.go) before this runs; journey_id is verified to
-- belong to the caller's org by the caller having already loaded the parent
-- journey row in the SAME transaction (GetJourneyForUpdate).
INSERT INTO journeys.journey_plan_items
    (id, organization_id, journey_id, apiary_id)
VALUES ($1, $2, $3, $4)
RETURNING id, organization_id, journey_id, apiary_id, created_at, deleted_at;

-- name: GetJourneyPlanItem :one
-- Org-scoped single-row read by the item's OWN client-generated id, no
-- deleted_at filter (mirrors GetJourneyForUpdate) — used to resolve a queued
-- delete op's journey_id/apiary_id (a delete op carries no `data`, per
-- PowerSync's own opData contract) and for idempotent-create comparisons.
SELECT id, organization_id, journey_id, apiary_id, created_at, deleted_at
FROM journeys.journey_plan_items
WHERE organization_id = $1 AND id = $2;

-- name: ListJourneyPlanItemsByJourney :many
-- A journey's current live plan (REST DTO's apiary_ids, sync-apply diffing,
-- and history's before/after apiary_ids computation) — org- and
-- journey-scoped, live rows only, oldest-added-first for deterministic
-- ordering.
SELECT id, organization_id, journey_id, apiary_id, created_at, deleted_at
FROM journeys.journey_plan_items
WHERE organization_id = $1 AND journey_id = $2 AND deleted_at IS NULL
ORDER BY created_at, id;

-- name: SoftDeleteJourneyPlanItem :execrows
-- Removes one apiary from a journey's plan by the item's OWN id — a plain
-- idempotent tombstone (0 rows affected is a legitimate "already gone"
-- no-op, never an error), mirroring SoftDeleteJourney's own shape.
UPDATE journeys.journey_plan_items
SET deleted_at = $3
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: InsertAuditLog :exec
-- Append-only history row (history.md §3-§4, FR-HIS-1) — changed_fields is
-- null for create/delete.
INSERT INTO journeys.audit_log
    (id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, changed_fields, change)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: ListAuditLog :many
-- The per-entity timeline read (FR-HIS-1) — not yet exposed via HTTP (no AC
-- in this milestone requires the view screens), kept as typed groundwork for
-- the entity-detail "history" screen, mirroring activities.ListAuditLog.
SELECT id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
FROM journeys.audit_log
WHERE organization_id = $1 AND entity_type = $2 AND entity_id = $3
ORDER BY recorded_at, id;

-- name: InsertConflict :exec
-- The LWW safety net (sync.md §4.2) for the `journey` entity type — mirrors
-- activities.sync_conflict_log's own InsertConflict query.
INSERT INTO journeys.sync_conflict_log
    (id, organization_id, entity_type, entity_id, winning_payload, losing_payload, winner, actor_user_id, occurred_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);
