-- +goose Up
-- journeys.audit_log — the append-only per-entity change history (FR-HIS-1),
-- same shape and immutability mechanism as activities.audit_log
-- (services/activities/store/migrations/00002_create_audit_log.sql,
-- history.md §3-§5). One immutable row per create/update/delete/close,
-- written synchronously in the same local transaction as the domain write —
-- on both the REST write path and the sync-apply path. A `journey_plan_item`
-- add/remove is folded into a `journey`-entity "update" row (changed_fields
-- includes "apiary_ids") rather than getting its own entity_type/row, so a
-- journey's combined history timeline stays one coherent per-journey story
-- (mirrors apiaries' own audit_log, where a hive-counter change is instead
-- logged under entity_type = 'apiary_counter' keyed by the apiary's id — this
-- service picks the "fold into the parent's own row" variant of that same
-- precedent since the plan is intrinsically part of "what a journey is").
--
-- Append-only immutability (history.md §7.1) is enforced OUTSIDE this
-- migration, by the same infra job apiaries.audit_log/activities.audit_log
-- use (infra/helm/beekeepingit/charts/postgres/templates/audit-immutability-job.yaml).
-- This migration itself grants nothing extra.
CREATE TABLE journeys.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,                              -- internal user UUID only, never PII
    occurred_at     TIMESTAMPTZ NOT NULL,               -- device time of the change
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server time the change was committed
    changed_fields  TEXT[],                             -- update: changed columns; null on create/delete
    change          JSONB NOT NULL                      -- the delta: baseline | {field:{from,to}} | tombstone
);

-- Per-entity timeline query (FR-HIS-1): "view the history of this journey",
-- org-scoped and time-ordered.
CREATE INDEX idx_journeys_audit_log_org_entity
    ON journeys.audit_log (organization_id, entity_type, entity_id, recorded_at);

-- +goose Down
DROP TABLE IF EXISTS journeys.audit_log;
