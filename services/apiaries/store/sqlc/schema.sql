-- sqlc's virtual schema for codegen only — NOT a bootstrap baseline, and never
-- applied to a database. It mirrors the cumulative "up" state of ../migrations/,
-- which since #541's squash is the single 00008_baseline.sql (plus any migration
-- added after it).
--
-- Keep in sync BY HAND when a migration changes a shape sqlc generates from. The
-- migrations are the real schema; this file only teaches sqlc the column types, so
-- drift surfaces as wrong generated Go types rather than as a failed migration —
-- which is exactly why it is worth stating here.

CREATE SCHEMA IF NOT EXISTS apiaries;

CREATE TABLE apiaries.apiaries (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    name            TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ,
    -- location is MANDATORY (FR-AP-7, #341, 00008_baseline.sql (previously 00008_apiary_location_not_null.sql)):
    -- an apiary can never exist without coordinates.
    location        public.geography(Point, 4326) NOT NULL,
    notes           TEXT CHECK (notes IS NULL OR char_length(notes) <= 10000),
    -- hive_count retired (#256, 00008_baseline.sql (previously 00005_create_apiary_counters.sql)) — hive
    -- count now lives in apiary_counters, a 1-N child table keyed by
    -- counter_type, not a column here.
    place_label     TEXT CHECK (place_label IS NULL OR char_length(place_label) <= 200),
    -- FR-AP-9 (#296, migration 00009): per-apiary OVERRIDE of the organization's
    -- DGAV registration-number default. NULL means "inherit the org default" --
    -- meaningfully distinct from an empty string, unlike the organizations
    -- column, which has no inheritance to opt out of.
    dgav_registration_number TEXT CHECK (dgav_registration_number IS NULL OR char_length(dgav_registration_number) <= 50)
);

-- apiary_counters — typed 1-N counters decoupled from apiaries (#256).
-- UNIQUE(organization_id, apiary_id, counter_type) (widened by
-- 00008_baseline.sql (previously 00007_apiary_counters_org_scoped_unique.sql), tenant-IDOR defense in
-- depth): an apiary can never hold two counters of the same type, and the
-- upsert's ON CONFLICT target itself now encodes tenancy, so it can never
-- collide across two different orgs' rows even in principle. counter_type
-- is validated against a known set in Go (api/counters.go), not a DB
-- enum/CHECK, so a future type is a code-only append (data-model.md §2
-- "Extensible enums" convention).
CREATE TABLE apiaries.apiary_counters (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    apiary_id       UUID NOT NULL REFERENCES apiaries.apiaries (id) ON DELETE CASCADE,
    counter_type    TEXT NOT NULL,
    value           INTEGER NOT NULL CHECK (value >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_apiary_counters_org_apiary_type UNIQUE (organization_id, apiary_id, counter_type)
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

-- stock_declarations — the "Declaração de Existências" log (#298, FR-AP-10,
-- migration 00010). Scoped to a DGAV registration number (FR-AP-9), not to an
-- apiary: the real declaration covers a beekeeper's whole holding. The number
-- is a plain text VALUE, not an FK — it is what was declared under, and must
-- not shift if the organization's or an apiary's number is later corrected.
-- `breakdown` is the per-apiary snapshot taken at record time, so a declaration
-- still shows what it covered after apiaries are renamed or deleted.
CREATE TABLE apiaries.stock_declarations (
    id                       UUID PRIMARY KEY,
    organization_id          UUID NOT NULL,
    dgav_registration_number TEXT NOT NULL DEFAULT '',
    declared_on              DATE NOT NULL,
    total_hive_count         INTEGER NOT NULL CHECK (total_hive_count >= 0),
    breakdown                JSONB NOT NULL DEFAULT '[]'::jsonb,
    notes                    TEXT CHECK (notes IS NULL OR char_length(notes) <= 2000),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL,
    recorded_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at               TIMESTAMPTZ
);
