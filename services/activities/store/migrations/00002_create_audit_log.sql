-- +goose Up
-- activities.audit_log — the append-only per-entity change history
-- (FR-HIS-1), same shape and immutability mechanism as
-- apiaries.audit_log (services/apiaries/store/migrations/00002_create_audit_log.sql,
-- history.md §3-§5). One immutable row per create/update/delete, written
-- synchronously in the same local transaction as the domain write — on both
-- the future REST write path and the sync-apply path (#39 and later). Created
-- now, alongside the owning table, so the schema is ready the moment #39
-- starts writing to it; apiaries followed the same order (audit_log added in
-- its own early migration, before either write path existed).
--
-- Append-only immutability (history.md §7.1) is enforced OUTSIDE this
-- migration, by the same infra job apiaries.audit_log uses
-- (infra/helm/beekeepingit/charts/postgres/templates/audit-immutability-job.yaml,
-- #62) — see that migration's header comment for the full mechanism. This
-- migration itself grants nothing extra.
CREATE TABLE activities.audit_log (
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

-- Per-entity timeline query (FR-HIS-1): "view the history of this activity",
-- org-scoped and time-ordered.
CREATE INDEX idx_activities_audit_log_org_entity
    ON activities.audit_log (organization_id, entity_type, entity_id, recorded_at);

-- +goose Down
DROP TABLE IF EXISTS activities.audit_log;
