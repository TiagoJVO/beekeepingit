-- name: ListApiaries :many
-- Org-scoped, live-row keyset page ordered by id (UUIDv7 ⇒ chronological).
-- Pass a null cursor for the first page; fetch limit+1 to detect a next page.
-- Used when the contract's `near` param is absent (FR-AP-2/#33);
-- ListApiariesByProximity below is the `near`-supplied, distance-ordered
-- variant.
SELECT id, organization_id, name, hive_count, created_at, updated_at,
       COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson
FROM apiaries.apiaries
WHERE organization_id = $1
  AND deleted_at IS NULL
  AND (sqlc.narg('cursor')::uuid IS NULL OR id > sqlc.narg('cursor')::uuid)
ORDER BY id
LIMIT $2;

-- name: ListApiariesByProximity :many
-- Org-scoped list ordered by ascending distance to the `near` reference
-- point (FR-AP-2, #33; D-6/PostGIS). Not keyset-paginated like ListApiaries
-- above: proximity order has no stable monotonic key to page on (a
-- distance tie, or simply re-issuing the same page, doesn't have the "id
-- always increases" property keyset pagination relies on), so this variant
-- is offset-paginated — acceptable given the contract's default page size
-- (50) already covers a realistic per-org apiary count and proximity
-- listing isn't expected to page deeply. Rows without a location sort last
-- (NULLS LAST) rather than being dropped, so an apiary missing a location
-- still appears (with a null distance_m) instead of silently vanishing
-- from the list. `public.geography`/`ST_MakePoint` follow
-- 00003_add_apiary_location.sql's schema-qualification note (bare
-- `geography` fails to resolve under the service's restricted
-- search_path).
--
-- ORDER BY uses the `<->` KNN distance operator rather than `distance_m`
-- itself: cheaper to evaluate (an index-accelerated bounding-box distance,
-- not the exact geodesic calculation), though the `organization_id`
-- equality filter here still forces a sequential scan over the org's own
-- rows rather than an index-only KNN traversal via idx_apiaries_location
-- (00003_add_apiary_location.sql) — confirmed with EXPLAIN: Postgres can't
-- combine "top-N nearest" index access with an arbitrary equality filter on
-- a different column without a matching partial/composite index, which
-- isn't worth adding for the realistic per-org apiary count this query
-- already assumes (see above). `<->` on `geography` is a fast
-- *approximate* distance (a few tenths of a percent off geodesic truth —
-- verified: ST_Distance and `<->` differ by ~0.1% at ~100km), fine for
-- ordering; the selected `distance_m` column still uses the exact
-- ST_Distance for the value actually returned to the client.
WITH ranked AS (
    SELECT id, organization_id, name, hive_count, created_at, updated_at,
           COALESCE(ST_AsGeoJSON(location), '')::text AS location_geojson,
           ST_Distance(location, ST_SetSRID(ST_MakePoint(sqlc.arg('lon')::double precision, sqlc.arg('lat')::double precision), 4326)::public.geography) AS distance_m,
           location <-> ST_SetSRID(ST_MakePoint(sqlc.arg('lon')::double precision, sqlc.arg('lat')::double precision), 4326)::public.geography AS knn_distance
    FROM apiaries.apiaries
    WHERE organization_id = $1
      AND deleted_at IS NULL
)
SELECT id, organization_id, name, hive_count, created_at, updated_at, location_geojson, distance_m
FROM ranked
ORDER BY knn_distance ASC NULLS LAST, id
LIMIT $2
OFFSET $3;

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
         ELSE ST_SetSRID(ST_MakePoint(sqlc.narg('lon')::double precision, sqlc.narg('lat')::double precision), 4326)::public.geography
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
                     ELSE ST_SetSRID(ST_MakePoint(sqlc.narg('lon')::double precision, sqlc.narg('lat')::double precision), 4326)::public.geography
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
