-- +goose Up
-- activities schema — the owning table for #38 (FR-AC-1, FR-TEN-2, EPIC-03
-- M3). Shape follows the same sync-publication conventions as
-- apiaries.apiaries (services/apiaries/store/migrations/00001_create_apiaries.sql):
-- client-supplied UUID PK, organization_id on every row (tenancy, FR-TEN-2),
-- created_at/updated_at, deleted_at tombstone. `updated_at` is the device
-- wall-clock LWW comparator, matching apiaries; `recorded_at` is the server
-- receive time. Both are populated now even though the write path that uses
-- them for LWW (the sync-apply endpoint) is #39's scope, not this one's — the
-- column shape is part of the data model this issue owns, and adding it now
-- avoids a follow-up migration once #39 lands.
--
-- `apiary_id`, `performed_by` and `journey_id` are CROSS-SERVICE soft
-- references (docs/architecture/service-decomposition.md §4 rule 2:
-- "cross-context references are by ID, not FK") — apiaries, identity/users
-- and journeys each own their own schema, so no FK constraint is possible or
-- desired here. `journey_id` is nullable and unused until M4 (journeys does
-- not exist yet), but D-21 ("Touches ... #38, #39, #46") explicitly calls out
-- that the activities table carries this stored attribution link from the
-- start, so the column is added now rather than as a future ALTER TABLE.
--
-- `type` is deliberately TEXT, not a DB enum/CHECK-constrained set: the known
-- set of activity types (harvest, feeding, treatment, generic) is validated
-- in the OWNING SERVICE (api/types.go's knownActivityTypes), mirroring the
-- data-model.md §2 "extensible enums" convention already used for apiaries'
-- counter_type/membership role — so adding a future activity type is a
-- code-only append (server + client constants), never a schema migration
-- (FR-AC-1 AC: "extensible ... new types = code-only").
--
-- `occurred_at` is the activity's own date — a field every type shares
-- (FR-AC-1: "date" appears in all four initial types) — promoted to a real
-- typed column (not part of the JSONB bag) since FR-AC-5/FR-AC-6 require
-- filtering activity lists by date range; a JSONB-buried date can't be
-- indexed/range-queried as cheaply. `attributes` then holds only the
-- TYPE-SPECIFIC fields (api/types.go's per-type schemas never include
-- "date").
--
-- The `activities` SCHEMA is provisioned by infra (postgres chart
-- bootstrap), not here — the least-privilege per-service role needs no
-- CREATE-on-database right (D-6). Integration tests create it in setup
-- before migrating, same as every other service.
CREATE TABLE activities.activities (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    apiary_id       UUID NOT NULL,
    performed_by    UUID NOT NULL,
    journey_id      UUID,
    type            TEXT NOT NULL,
    occurred_at     DATE NOT NULL,
    attributes      JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL,               -- device time; LWW comparator (future #39)
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server receive time
    deleted_at      TIMESTAMPTZ                         -- soft-delete tombstone (future #39/#41)
);

-- Org-scoped, apiary-detail read path (FR-AC-5: "list of all activities for
-- that apiary, filterable by activity type and date range") — live rows
-- only, newest first.
CREATE INDEX idx_activities_org_apiary_live
    ON activities.activities (organization_id, apiary_id, occurred_at DESC)
    WHERE deleted_at IS NULL;

-- Org-wide read path (FR-AC-6: "list of all activities across all apiaries,
-- filterable by activity type and date range").
CREATE INDEX idx_activities_org_type_live
    ON activities.activities (organization_id, type, occurred_at DESC)
    WHERE deleted_at IS NULL;

-- Journey aggregation (D-21, FR-JO-1): every activity attributed to a given
-- journey, once #46 starts writing journey_id.
CREATE INDEX idx_activities_org_journey_live
    ON activities.activities (organization_id, journey_id)
    WHERE deleted_at IS NULL AND journey_id IS NOT NULL;

-- sync_conflict_log — the LWW safety net (sync.md §4.2), same shape as
-- apiaries.sync_conflict_log. Co-located in this service's own schema
-- (ownership rule 1), created now alongside the owning table even though the
-- sync-apply endpoint that writes to it is #39's scope — matching how
-- apiaries created its own sync_conflict_log in the same migration as
-- apiaries.apiaries, before any write path existed yet.
CREATE TABLE activities.sync_conflict_log (
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

CREATE INDEX idx_activities_conflict_org_entity
    ON activities.sync_conflict_log (organization_id, entity_type, entity_id);

-- +goose Down
DROP TABLE IF EXISTS activities.sync_conflict_log;
DROP TABLE IF EXISTS activities.activities;
