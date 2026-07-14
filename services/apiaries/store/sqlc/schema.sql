-- sqlc's virtual schema for codegen only — mirrors the "up" side of
-- ../migrations/00001_create_apiaries.sql, 00002_create_audit_log.sql,
-- 00003_add_apiary_location.sql, 00004_add_apiary_notes.sql,
-- 00005_create_apiary_counters.sql and 00006_add_apiary_place_label.sql (no
-- down migration; runtime schema changes only ever happen via goose). Update
-- all files together.
CREATE SCHEMA IF NOT EXISTS apiaries;

CREATE TABLE apiaries.apiaries (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    name            TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    location        public.geography(Point, 4326),
    notes           TEXT CHECK (notes IS NULL OR char_length(notes) <= 10000),
    -- hive_count retired (#256, 00005_create_apiary_counters.sql) — hive
    -- count now lives in apiary_counters, a 1-N child table keyed by
    -- counter_type, not a column here.
    place_label     TEXT CHECK (place_label IS NULL OR char_length(place_label) <= 200)
);

-- apiary_counters — typed 1-N counters decoupled from apiaries (#256).
-- UNIQUE(apiary_id, counter_type): an apiary can never hold two counters of
-- the same type. counter_type is validated against a known set in Go
-- (api/counters.go), not a DB enum/CHECK, so a future type is a code-only
-- append (data-model.md §2 "Extensible enums" convention).
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

CREATE TABLE apiaries.sync_conflict_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    winning_payload JSONB NOT NULL,
    losing_payload  JSONB NOT NULL,
    winner          TEXT NOT NULL CHECK (winner IN ('server', 'client')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE apiaries.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_fields  TEXT[],
    change          JSONB NOT NULL
);
