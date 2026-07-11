-- name: ListApiaries :many
-- Org-scoped, live-row keyset page ordered by id (UUIDv7 ⇒ chronological).
-- Pass a null cursor for the first page; fetch limit+1 to detect a next page.
SELECT id, organization_id, name, hive_count, created_at, updated_at,
       COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson
FROM apiaries.apiaries
WHERE organization_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('cursor')::uuid IS NULL OR id > sqlc.narg('cursor')::uuid)
ORDER BY id
LIMIT $2;

-- name: GetApiary :one
SELECT id, organization_id, name, hive_count, created_at, updated_at,
       COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson
FROM apiaries.apiaries
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: GetApiaryForUpdate :one
-- Locks the row (or reports its absence) for the LWW apply / REST
-- create-or-update transaction.
SELECT id, organization_id, name, hive_count, created_at, updated_at, deleted_at,
       COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson
FROM apiaries.apiaries
WHERE organization_id = $1 AND id = $2
FOR UPDATE;

-- name: InsertApiary :exec
-- Sync-apply create (no location — the sync wire shape carries only
-- name/hive_count, sync.go's apiaryData). REST create uses InsertApiaryWithLocation.
INSERT INTO apiaries.apiaries (id, organization_id, name, hive_count, updated_at, deleted_at)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: InsertApiaryWithLocation :one
-- REST create (POST /v1/apiaries, #31): full row including the optional
-- GeoJSON location. sqlc.narg('lon')/sqlc.narg('lat') are both-or-neither —
-- callers pass either both valid or both NULL (api/apiaries.go's toPoint).
INSERT INTO apiaries.apiaries (id, organization_id, name, hive_count, updated_at, location)
VALUES (
    $1, $2, $3, $4, $5,
    CASE WHEN sqlc.narg('lon')::double precision IS NULL THEN NULL
         ELSE ST_SetSRID(ST_MakePoint(sqlc.narg('lon')::double precision, sqlc.narg('lat')::double precision), 4326)::geography
    END
)
RETURNING id, organization_id, name, hive_count, created_at, updated_at,
          COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson;

-- name: UpdateApiary :exec
-- Sync-apply update (name/hive_count/tombstone only — location is not part
-- of the sync wire shape yet). REST update uses UpdateApiaryWithLocation.
UPDATE apiaries.apiaries
SET name = $3, hive_count = $4, updated_at = $5, deleted_at = $6, recorded_at = now()
WHERE organization_id = $1 AND id = $2;

-- name: UpdateApiaryWithLocation :one
-- REST update (PATCH /v1/apiaries/{id}, #31): the caller computes the full
-- desired row first (matching sync.go's mergeOp pattern), so this always
-- sets every mutable column.
UPDATE apiaries.apiaries
SET name = $3,
    hive_count = $4,
    updated_at = $5,
    location = CASE WHEN sqlc.narg('lon')::double precision IS NULL THEN NULL
                     ELSE ST_SetSRID(ST_MakePoint(sqlc.narg('lon')::double precision, sqlc.narg('lat')::double precision), 4326)::geography
               END,
    recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL
RETURNING id, organization_id, name, hive_count, created_at, updated_at,
          COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson;

-- name: SoftDeleteApiary :execrows
-- REST delete (DELETE /v1/apiaries/{id}, #31): tombstone, matching the sync
-- path's deleted_at convention so the delete propagates to devices
-- (data-model.md). :execrows so the caller can distinguish "already gone"
-- (0 rows) from success without a separate SELECT.
UPDATE apiaries.apiaries
SET deleted_at = $3, updated_at = $3, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

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
