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

-- name: GetActivityForUpdate :one
-- Locks the row (or reports its absence, including a soft-deleted one) for
-- the REST update/delete transaction and the sync-apply LWW compare
-- (#40/#41, mirrors apiaries' GetApiaryForUpdate). No deleted_at filter —
-- callers explicitly check the returned row's deleted_at: REST 404s a
-- tombstoned row (updateActivity/deleteActivity), while sync-apply's LWW
-- still applies OVER a tombstone (a strictly-newer offline edit can
-- legitimately "undelete" the row) — symmetric with apiaries' own sync.go
-- convention.
SELECT id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes,
       created_at, updated_at, recorded_at, deleted_at
FROM activities.activities
WHERE organization_id = $1 AND id = $2
FOR UPDATE;

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

-- name: UpdateActivity :one
-- REST update (PATCH /v1/activities/{id}, #40/FR-AC-3): the caller computes
-- the full desired row first (matching sync.go's mergeActivityOp pattern),
-- so this always sets every mutable column. performed_by is NEVER written
-- here — FR-TEN-2 attribution is set once at create and immutable on edit,
-- matching InsertActivity's own performed_by convention; journey_id is
-- similarly untouched (D-21/#46 owns journey re-attribution, out of this
-- issue's scope). WHERE deleted_at IS NULL is defense-in-depth — the
-- handler already 404s a tombstoned row via its own GetActivityForUpdate
-- check before reaching here.
UPDATE activities.activities
SET apiary_id = $3, type = $4, occurred_at = $5, attributes = $6, updated_at = $7, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL
RETURNING id, organization_id, apiary_id, performed_by, journey_id, type, occurred_at, attributes,
          created_at, updated_at, recorded_at, deleted_at;

-- name: UpdateActivitySync :exec
-- Sync-apply put/patch/delete (#40/#41/#387, mirrors apiaries' UpdateApiary):
-- sets every mutable column, INCLUDING deleted_at (a tombstone is just
-- another LWW-compared field, sync.md §4.5) and, as of #387, journey_id —
-- the caller (applyActivityOp's mergeActivityOp) computes the full desired
-- row first, including journey_id's tri-state absent-keeps/null-clears/
-- uuid-relinks resolution (mergeActivityOp's own doc comment). performed_by
-- is NEVER written here (FR-TEN-2 attribution stays immutable, same
-- rationale as UpdateActivity above) — journey_id is the one asymmetry
-- between this query and the REST UpdateActivity above: mutable HERE
-- (sync-only, #387), still untouched there (REST re-linking is out of this
-- issue's scope; #387's own design doc).
UPDATE activities.activities
SET apiary_id = $3, type = $4, occurred_at = $5, attributes = $6, journey_id = $9, updated_at = $7, deleted_at = $8, recorded_at = now()
WHERE organization_id = $1 AND id = $2;

-- name: SoftDeleteActivity :execrows
-- REST delete (DELETE /v1/activities/{id}, #41/FR-AC-4): tombstone,
-- matching the sync path's deleted_at convention so the delete propagates
-- to devices (FR-OF-1) — the PowerSync Sync Rules already filter
-- deleted_at IS NULL (infra/helm/beekeepingit/charts/powersync/values.yaml).
-- :execrows so the caller can distinguish "already gone" (0 rows) from
-- success without a separate SELECT, mirroring apiaries' SoftDeleteApiary.
UPDATE activities.activities
SET deleted_at = $3, updated_at = $3, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

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

-- name: ListEntityTimeline :many
-- The combined per-entity timeline (#60 AC, history.md §6), mirroring
-- apiaries' ListEntityTimeline query (services/apiaries/store/sqlc/queries/
-- apiaries.sql, #61) exactly, against this service's own audit_log/
-- sync_conflict_log tables: UNIONs activities.audit_log (applied
-- create/update/delete rows, event_kind = change_type) with
-- activities.sync_conflict_log (LWW-loss rows, event_kind hardcoded
-- 'superseded' — mirrors history.EventSuperseded — history.md §6 "LWW
-- losers... surfaced as a superseded timeline event, not silently
-- overwritten"), ordered chronologically. change carries the audit delta for
-- audit_log rows and the {winning_payload, losing_payload, winner} conflict
-- payload for sync_conflict_log rows — the two tables' change shapes differ
-- by design (§3 vs §4.2), so callers branch on event_kind to interpret it.
-- Exposed via HTTP from the moment it's added (GET /v1/activities/{id}/
-- history, #60) — activities had no prior "typed groundwork, no HTTP surface
-- yet" stage for it, unlike apiaries' own copy of this query, which sat
-- unexposed between #61 and #60 and is now served by that service's
-- equivalent route.
SELECT timeline.id, timeline.organization_id, timeline.entity_type, timeline.entity_id,
       timeline.event_kind, timeline.actor_user_id, timeline.occurred_at, timeline.recorded_at,
       timeline.changed_fields, timeline.change
FROM (
    SELECT al.id, al.organization_id, al.entity_type, al.entity_id, al.change_type AS event_kind,
           al.actor_user_id, al.occurred_at, al.recorded_at, al.changed_fields, al.change
    FROM activities.audit_log al
    WHERE al.organization_id = $1 AND al.entity_type = $2 AND al.entity_id = $3

    UNION ALL

    SELECT scl.id, scl.organization_id, scl.entity_type, scl.entity_id, 'superseded' AS event_kind,
           scl.actor_user_id, scl.occurred_at, scl.recorded_at, NULL::text[] AS changed_fields,
           jsonb_build_object('winning_payload', scl.winning_payload, 'losing_payload', scl.losing_payload, 'winner', scl.winner) AS change
    FROM activities.sync_conflict_log scl
    WHERE scl.organization_id = $1 AND scl.entity_type = $2 AND scl.entity_id = $3
) timeline
ORDER BY timeline.recorded_at, timeline.id;
