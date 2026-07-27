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
-- Append-only immutability (history.md §7.1) is enforced OUTSIDE this
-- migration, by infra/helm/beekeepingit/charts/postgres/templates/
-- audit-immutability-job.yaml (#62): this migration runs as apiaries_svc
-- (dbaccess.Migrate uses the same DSN/role as the runtime pool), so
-- apiaries_svc is this table's owner immediately after CREATE TABLE, and a
-- same-role REVOKE can't durably restrict an owner (it can always GRANT the
-- privilege back to itself, or ALTER/DROP/TRUNCATE regardless of REVOKE).
-- The privileged post-install/post-upgrade Job instead moves OWNERSHIP to
-- beekeepingit and grants apiaries_svc only INSERT/SELECT — see that file's
-- header comment for the full mechanism and services/shared/dbaccess/
-- audit_immutability_test.go for the testcontainers proof. This migration
-- itself grants nothing extra; the current (dev-cluster, pre-#62) role's
-- INSERT/SELECT/UPDATE/DELETE stays as-is until that Job runs.
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
