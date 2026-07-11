-- +goose Up
-- apiaries.audit_log — the append-only per-entity change history (#59,
-- history.md §3-§5). One immutable row per create/update/delete, written
-- synchronously in the same local transaction as the domain write, on both
-- the online write path (future, #31) and the sync-apply path (sync.go).
--
-- Placement mirrors sync_conflict_log (00001): co-located in this service's
-- own schema (ownership rule 1 — a service writes only its own schema), not
-- a central history table.
--
-- NOTE: append-only immutability (the runtime role losing UPDATE/DELETE
-- grants, history.md §7.1) is explicitly out of scope here — that's #62, a
-- later wave. This migration only creates the table + the INSERT/SELECT
-- access the current (unrestricted dev) role already has.
CREATE TABLE apiaries.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,                              -- internal user UUID only, never PII (§7.3)
    occurred_at     TIMESTAMPTZ NOT NULL,               -- device time of the change (§6)
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server time the change was committed
    changed_fields  TEXT[],                             -- update: changed columns; null on create/delete
    change          JSONB NOT NULL                      -- the delta (§3): baseline | {field:{from,to}} | tombstone
);

-- Per-entity timeline query (FR-HIS-1, §8): "view the history of this
-- apiary", org-scoped and time-ordered.
CREATE INDEX idx_audit_log_org_entity
    ON apiaries.audit_log (organization_id, entity_type, entity_id, recorded_at);

-- +goose Down
DROP TABLE IF EXISTS apiaries.audit_log;
