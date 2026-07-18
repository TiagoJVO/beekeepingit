-- +goose Up
-- journeys schema — the owning tables for #45 (FR-JO-4, FR-TEN-2, EPIC-04
-- M4). Shape follows the same sync-publication conventions as
-- activities.activities (services/activities/store/migrations/00001_create_activities.sql):
-- client-supplied UUID PK, organization_id on every row (tenancy, FR-TEN-2),
-- created_at/updated_at/recorded_at, deleted_at tombstone.
--
-- `main_activity_type` is deliberately TEXT, not a DB enum/CHECK-constrained
-- set: it is validated in THIS service (api/types.go's knownMainActivityTypes,
-- a hand-kept mirror of services/activities/api/types.go's own registry —
-- journeys does not import the activities Go module, since a service only
-- ever depends on another service's schema by ID [service-decomposition.md
-- rule 2], never by code), mirroring the data-model.md §2 "extensible enums"
-- convention already used for activities' own `type` column.
--
-- `status` is likewise TEXT + CHECK, not a rigid enum, per the SAME
-- convention (D-21: "open"/"closed" is the known set today; a future status
-- would be a code-only append, same as activities' type registry). D-21
-- narrows FR-JO-4 to ONE main activity type per journey (this column) — a
-- manual per-apiary planned-activity-type list is an explicitly deferred
-- future extension (see journey_plan_items below).
--
-- The `journeys` SCHEMA is provisioned by infra (postgres chart bootstrap,
-- already present in infra/helm/beekeepingit/charts/postgres/values.yaml's
-- `schemas` list ahead of this service existing), not here — the
-- least-privilege per-service role needs no CREATE-on-database right (D-6).
-- Integration tests create it in setup before migrating, same as every other
-- service.
CREATE TABLE journeys.journeys (
    id                  UUID PRIMARY KEY,
    organization_id     UUID NOT NULL,
    name                TEXT NOT NULL,
    main_activity_type  TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL,               -- device time; LWW comparator
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT now(), -- server receive time
    deleted_at          TIMESTAMPTZ                         -- soft-delete tombstone
);

-- Org-scoped list read (#47's filterable main list; #46's open-journey
-- picker match), live rows only, newest first.
CREATE INDEX idx_journeys_org_status_live
    ON journeys.journeys (organization_id, status, created_at DESC)
    WHERE deleted_at IS NULL;

-- journey_plan_items — the "apiaries to visit" plan (FR-JO-4). apiary_id is a
-- CROSS-SERVICE soft reference (docs/architecture/service-decomposition.md §4
-- rule 2: "cross-context references are by ID, not FK") — apiaries owns its
-- own schema, so no FK constraint is possible or desired here; every write
-- path verifies it against the apiaries service itself
-- (api/apiaries_client.go's ApiaryVerifier) before writing anything.
--
-- `id` is a real, stable, client-generated identity shared by client and
-- server (matching activities.activities' own convention) — NOT a synthetic
-- upsert-by-(journey_id,apiary_id) key like apiaries.apiary_counters uses.
-- That lets a plan-item removal be a plain, idempotent tombstone-by-id: no
-- enrichment of a queued delete op's payload is needed (a delete op carries
-- no `data` at all, per PowerSync's own CrudEntry.opData contract), unlike
-- the counter-identity re-attachment client/lib/core/sync/powersync_connector.dart's
-- `_toOp` has to do for apiary_counters.
--
-- deleted_at is this table's own soft-delete tombstone (removing an apiary
-- from a journey's plan), mirroring activities' convention rather than a
-- hard DELETE — kept soft so a re-added apiary after removal is a fresh
-- INSERT (never violates the partial unique index below) and so history can
-- reconstruct "this apiary was removed from the plan, then re-added" if ever
-- needed. No `updated_at`: a plan-item row has no mutable content of its own
-- once created (journey_id/apiary_id never change) — it is either live or
-- tombstoned, nothing in between to LWW-compare.
CREATE TABLE journeys.journey_plan_items (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    journey_id      UUID NOT NULL REFERENCES journeys.journeys(id) ON DELETE CASCADE,
    apiary_id       UUID NOT NULL, -- soft ref -> apiaries.apiaries (no FK, cross-schema)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

-- Read a journey's current plan (REST DTO, sync-apply diffing), live rows only.
CREATE INDEX idx_journey_plan_items_org_journey_live
    ON journeys.journey_plan_items (organization_id, journey_id)
    WHERE deleted_at IS NULL;

-- An apiary can appear at most once in a given journey's LIVE plan — a
-- partial unique index (not a plain UNIQUE) so a removed-then-re-added
-- apiary (a fresh INSERT after the old row was tombstoned) never collides
-- with its own tombstoned predecessor, mirroring the "extensible enums +
-- soft delete" combination already used for organizations.invitations'
-- "at most one pending invite per address per org" partial index
-- (docs/architecture/data-model.md §3's "as built" note).
CREATE UNIQUE INDEX uq_journey_plan_items_journey_apiary_live
    ON journeys.journey_plan_items (journey_id, apiary_id)
    WHERE deleted_at IS NULL;

-- sync_conflict_log — the LWW safety net (sync.md §4.2) for the `journey`
-- entity type, same shape as activities.sync_conflict_log. journey_plan_item
-- ops are pure set-membership (add/remove), so they have no "content" to
-- LWW-compare and never write here (api/sync.go's own doc comment).
CREATE TABLE journeys.sync_conflict_log (
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

CREATE INDEX idx_journeys_conflict_org_entity
    ON journeys.sync_conflict_log (organization_id, entity_type, entity_id);

-- +goose Down
DROP TABLE IF EXISTS journeys.sync_conflict_log;
DROP TABLE IF EXISTS journeys.journey_plan_items;
DROP TABLE IF EXISTS journeys.journeys;
