-- apiary_counters — typed 1-N counters decoupled from apiaries (#256,
-- FR-AP-7, D-2 note, 00005_create_apiary_counters.sql). One row per
-- (apiary, counter_type); a future counter type (nucs, supers, queens, ...)
-- is a code-only append to the known set (api/counters.go), never a new
-- migration or new query here — every type shares these same four queries.

-- name: UpsertApiaryCounter :one
-- Enforces "only one row per (apiary, type)" via ON CONFLICT on the table's
-- UNIQUE(apiary_id, counter_type) constraint — an upsert, not a
-- check-then-insert/update pair, so this is safe under concurrent writers
-- (two offline devices both setting the hive count) without an explicit
-- application-level lock. Callers (api/counters.go's upsertHiveCounter) pass
-- a fresh id on every call; on a genuine insert it's used, on a conflict
-- (existing row) it's discarded in favor of the stored id — RETURNING always
-- reports the row's real, stable id either way.
INSERT INTO apiaries.apiary_counters (id, organization_id, apiary_id, counter_type, value, updated_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (apiary_id, counter_type)
DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
RETURNING id, organization_id, apiary_id, counter_type, value, created_at, updated_at;

-- name: GetApiaryCounter :one
-- One counter type for one apiary — used where only a single type's value is
-- needed (e.g. resolving the hive count for a REST/sync read of one apiary).
-- Org-scoped directly on this table (not via a join to apiaries) since a
-- counter row always carries its own organization_id (data-model.md §5).
SELECT id, organization_id, apiary_id, counter_type, value, created_at, updated_at
FROM apiaries.apiary_counters
WHERE organization_id = $1 AND apiary_id = $2 AND counter_type = $3;

-- name: ListApiaryCounters :many
-- Every known-type counter row that EXISTS for one apiary (FR-AP-7 detail
-- screen AC: hives always renders even with no row — the caller fills that
-- default in Go, api/counters.go's countersForDetail — other known types
-- render only when a row exists here). Ordered by counter_type for a stable,
-- deterministic response.
SELECT id, organization_id, apiary_id, counter_type, value, created_at, updated_at
FROM apiaries.apiary_counters
WHERE organization_id = $1 AND apiary_id = $2
ORDER BY counter_type;
