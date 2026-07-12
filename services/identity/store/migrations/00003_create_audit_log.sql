-- +goose Up
-- identity.audit_log — the append-only per-entity change history (#165,
-- history.md §3-§5), extending #59's apiaries.audit_log pattern to the
-- identity.users entity. One immutable row per profile create/update,
-- written synchronously in the same local transaction as the domain write
-- (getProfile's UpsertUserOnFirstSeen, updateProfile's UpdateUserProfile —
-- api/profile.go).
--
-- Placement mirrors apiaries.audit_log: co-located in this service's own
-- schema (ownership rule 1 — a service writes only its own schema), not a
-- central history table.
--
-- Unlike apiaries.audit_log, organization_id is NULLABLE here, not NOT NULL:
-- identity.users is a global, non-org-owned entity (history.md §9 — "records
-- only minimal self-profile changes; it is global (not org-owned) and
-- carries no organization_id"), so a profile's own audit rows have no
-- tenant to scope to. The column is kept (rather than dropped) only so this
-- table shares entity_type/entity_id/change_type/actor_user_id/occurred_at/
-- recorded_at/changed_fields/change with every other service's audit_log —
-- the shared history.Entry shape (services/shared/history) — without a
-- special case; it is simply always NULL for this service's rows today.
--
-- NOTE: append-only immutability (the runtime role losing UPDATE/DELETE
-- grants, history.md §7.1) is explicitly out of scope here — that's #62, a
-- later wave. This migration only creates the table + the INSERT/SELECT
-- access the current (unrestricted dev) role already has.
CREATE TABLE identity.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID,                              -- always NULL: identity.users is global, not org-owned (history.md §9)
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,                              -- internal user UUID only, never PII (§7.3)
    occurred_at     TIMESTAMPTZ NOT NULL,               -- device/request time of the change (§6)
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server time the change was committed
    changed_fields  TEXT[],                             -- update: changed columns; null on create/delete
    change          JSONB NOT NULL                      -- the delta (§3): baseline | {field:{from,to}} | tombstone
);

-- Per-entity timeline query (FR-HIS-1, §8): "view the history of this
-- profile", time-ordered. No organization_id in the index (unlike apiaries)
-- since it's always null here.
CREATE INDEX idx_audit_log_entity
    ON identity.audit_log (entity_type, entity_id, recorded_at);

-- +goose Down
DROP TABLE IF EXISTS identity.audit_log;
