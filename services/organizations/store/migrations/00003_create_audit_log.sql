-- +goose Up
-- organizations.audit_log — the append-only per-entity change history (#165,
-- history.md §3-§5), extending #59's apiaries.audit_log pattern to this
-- service's three entities: organizations, memberships and invitations
-- (history.md §9's "memberships, organizations, invitations | organizations
-- | organizations.audit_log (admin actions)"). One immutable row per
-- create/update/delete/accept/revoke, written synchronously in the same
-- local transaction as the domain write.
--
-- entity_type is the polymorphic discriminator (history.md §3) that tells
-- these three entities' rows apart in this one shared table: 'organization' |
-- 'membership' | 'invitation'.
--
-- organization_id IS NOT NULL here (unlike identity.audit_log): every row
-- this service writes describes something that belongs to exactly one
-- organization — including the 'organization' entity_type's own create row,
-- whose organization_id is that same organization's id (the tenant root is
-- its own scope, matching organizations.organizations' own PK — see
-- api/organizations.go's audit wiring).
--
-- Placement mirrors apiaries.audit_log: co-located in this service's own
-- schema (ownership rule 1 — a service writes only its own schema), not a
-- central history table.
--
-- NOTE: append-only immutability (the runtime role losing UPDATE/DELETE
-- grants, history.md §7.1) is explicitly out of scope here — that's #62, a
-- later wave. This migration only creates the table + the INSERT/SELECT
-- access the current (unrestricted dev) role already has.
CREATE TABLE organizations.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL CHECK (entity_type IN ('organization', 'membership', 'invitation')),
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,                              -- internal user UUID only, never PII (§7.3)
    occurred_at     TIMESTAMPTZ NOT NULL,               -- device/request time of the change (§6)
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server time the change was committed
    changed_fields  TEXT[],                             -- update: changed columns; null on create/delete
    change          JSONB NOT NULL                      -- the delta (§3): baseline | {field:{from,to}} | tombstone
);

-- Per-entity timeline query (FR-HIS-1, §8): "view the history of this org /
-- membership / invitation", org-scoped and time-ordered.
CREATE INDEX idx_audit_log_org_entity
    ON organizations.audit_log (organization_id, entity_type, entity_id, recorded_at);

-- +goose Down
DROP TABLE IF EXISTS organizations.audit_log;
