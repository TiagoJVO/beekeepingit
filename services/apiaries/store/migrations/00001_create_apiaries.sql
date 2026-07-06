-- +goose Up
-- apiaries schema — the walking skeleton's trivial record (walking-skeleton.md
-- §4.1). Shape follows the sync publication contract (sync.md §5.1): client
-- UUIDv7 PK, organization_id on every row, created_at/updated_at, deleted_at
-- tombstone. `updated_at` is the device wall-clock LWW comparator (§4.3);
-- `recorded_at` is the server receive time.
--
-- The `apiaries` SCHEMA is provisioned by infra (postgres chart bootstrap), not
-- here, so the least-privilege per-service role needs no CREATE-on-database
-- right (D-6). Integration tests create it in setup before migrating.
CREATE TABLE apiaries.apiaries (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    name            TEXT NOT NULL,
    hive_count      INTEGER NOT NULL DEFAULT 0 CHECK (hive_count >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL,            -- device time; LWW comparator (§4.3)
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server receive time
    deleted_at      TIMESTAMPTZ                      -- soft-delete tombstone (§4.5)
    -- NOTE: `location geography(Point, 4326)` (data-model.md §3) is added by
    -- EPIC-02 (#31) when proximity (FR-AP-2/5) is built. The walking skeleton
    -- deliberately does not exercise PostGIS (walking-skeleton.md §4.1), so the
    -- column is omitted here — an additive migration adds it later.
);

-- Org-scoped keyset listing of live rows (the read path, §5.1).
CREATE INDEX idx_apiaries_org_live
    ON apiaries.apiaries (organization_id, id)
    WHERE deleted_at IS NULL;

-- sync_conflict_log — the LWW safety net (sync.md §4.2). Every LWW loss writes
-- a row here so no offline edit is silently discarded; co-located in this
-- service's own schema, written in the same apply transaction as the (future)
-- audit row (history.md §6).
CREATE TABLE apiaries.sync_conflict_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    winning_payload JSONB NOT NULL,
    losing_payload  JSONB NOT NULL,
    winner          TEXT NOT NULL CHECK (winner IN ('server', 'client')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ,                    -- device time of the losing edit
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_conflict_org_entity
    ON apiaries.sync_conflict_log (organization_id, entity_type, entity_id);

-- +goose Down
DROP TABLE IF EXISTS apiaries.sync_conflict_log;
DROP TABLE IF EXISTS apiaries.apiaries;
