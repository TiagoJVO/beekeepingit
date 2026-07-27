-- +goose Up
-- todos.audit_log — the append-only per-entity change history (FR-HIS-1),
-- byte-for-byte the same shape as activities.audit_log
-- (services/activities/store/migrations/00002_create_audit_log.sql,
-- history.md §3-§5). One immutable row per create/update/delete, written
-- synchronously in the same local transaction as the domain write — on both
-- the REST write path and the sync-apply path (api/write.go,
-- api/sync.go). A todo's complete/reopen lifecycle transitions are recorded
-- as ordinary change_type='update' rows (changed_fields=['status',
-- 'completed_at']) — no dedicated change_type is needed for them.
--
-- Append-only immutability (history.md §7.1) is enforced OUTSIDE this
-- migration, by the same infra job activities.audit_log uses
-- (infra/helm/beekeepingit/charts/postgres/templates/audit-immutability-job.yaml,
-- #62) — that job already loops .Values.schemas, which includes `todos`
-- (infra/helm/beekeepingit/values.yaml), so no infra change is needed here.
CREATE TABLE todos.audit_log (
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

-- Per-entity timeline query (FR-HIS-1): "view the history of this todo",
-- org-scoped and time-ordered.
CREATE INDEX idx_todos_audit_log_org_entity
    ON todos.audit_log (organization_id, entity_type, entity_id, recorded_at);

-- +goose Down
DROP TABLE IF EXISTS todos.audit_log;
