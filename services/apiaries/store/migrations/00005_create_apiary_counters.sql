-- +goose Up
-- apiary_counters — decouples typed 1-N counters from the apiaries table
-- (FR-AP-7, D-2 note on current-state counters vs activity-attribute
-- events, #256, 2026-07-13 user decision). Hive count was previously a
-- column directly on apiaries.apiaries (00001_create_apiaries.sql); every
-- future countable (nucs, supers, queens, ...) would otherwise mean altering
-- that table again. This table holds one row per (apiary, counter_type),
-- enforced by the UNIQUE constraint below — an apiary can never carry two
-- counters of the same type.
--
-- `counter_type` is deliberately `text`, NOT a DB enum/CHECK-constrained set:
-- the known set of types (initially just "hive") is validated in the OWNING
-- SERVICE's Go code (services/apiaries/api/counters.go's knownCounterTypes),
-- mirroring the data-model.md §2 "Extensible enums" convention already used
-- for activity `type`/membership `role` — so adding a future counter type is
-- a code-only append (client + server constants), never a schema migration.
--
-- organization_id (tenancy rule, every owned table carries it) + apiary_id FK
-- (ON DELETE CASCADE — a counter has no existence independent of its apiary)
-- mirror apiaries.apiaries' own shape; created_at/updated_at follow the same
-- convention (data-model.md §2), though updated_at here is server-authoritative
-- (this table isn't independently LWW-synced the way apiaries.apiaries is —
-- see sync.go's counterData handling for how counter writes ride the existing
-- `apiary` sync-apply op instead of a new one).
CREATE TABLE apiaries.apiary_counters (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    apiary_id       UUID NOT NULL REFERENCES apiaries.apiaries (id) ON DELETE CASCADE,
    counter_type    TEXT NOT NULL,
    value           INTEGER NOT NULL CHECK (value >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_apiary_counters_apiary_type UNIQUE (apiary_id, counter_type)
);

-- Org-scoped lookup (every read is org-scoped, data-model.md §5) + the natural
-- access pattern "this apiary's counters" (detail screen, list/marker hive
-- sourcing) — the UNIQUE constraint above already gives apiary_id a b-tree
-- index; this composite index instead serves the org-scoped multi-apiary
-- reads (ListCountersForOrg-shaped queries) sqlc's queries.sql adds.
CREATE INDEX idx_apiary_counters_org_apiary
    ON apiaries.apiary_counters (organization_id, apiary_id);

-- Data migration: one `hive` counter row per existing apiary, carrying its
-- current hive_count value forward before the column is retired below. A
-- deterministic id (uuid_generate_v5-style would need an extra extension;
-- gen_random_uuid() from pgcrypto, already available via postgis's
-- dependency chain on this cluster, is simpler and the id has no meaning
-- callers depend on) — organization_id/apiary_id carry the real linkage.
-- updated_at/created_at backfill from the apiary's own updated_at (the best
-- available "when was this count last true" signal) so the counter row
-- doesn't claim a fresher change than actually happened.
INSERT INTO apiaries.apiary_counters (id, organization_id, apiary_id, counter_type, value, created_at, updated_at)
SELECT gen_random_uuid(), organization_id, id, 'hive', hive_count, updated_at, updated_at
FROM apiaries.apiaries;

-- Retire the column now decoupled into apiary_counters (walking-skeleton
-- phase, no legacy clients to support mid-migration — #256 AC). Coordinated
-- in this same PR with the sync-rules bucket, the REST/sync wire shape (which
-- keeps the `hive_count` JSON field name, now served from apiary_counters
-- underneath — services/apiaries/api/counters.go), and the client schema.
ALTER TABLE apiaries.apiaries DROP COLUMN hive_count;

-- +goose Down
ALTER TABLE apiaries.apiaries ADD COLUMN hive_count INTEGER NOT NULL DEFAULT 0 CHECK (hive_count >= 0);

UPDATE apiaries.apiaries a
SET hive_count = COALESCE(
    (SELECT c.value FROM apiaries.apiary_counters c
     WHERE c.apiary_id = a.id AND c.counter_type = 'hive'),
    0
);

DROP INDEX IF EXISTS apiaries.idx_apiary_counters_org_apiary;
DROP TABLE IF EXISTS apiaries.apiary_counters;
