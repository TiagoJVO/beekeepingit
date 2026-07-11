-- sqlc's virtual schema for codegen only — mirrors the "up" side of
-- ../migrations/00001_create_organizations.sql and 00002_create_invitations.sql
-- (no down migration; runtime schema changes only ever happen via goose).
-- Update these files together.
CREATE SCHEMA IF NOT EXISTS organizations;

CREATE TABLE organizations.organizations (
    id         UUID PRIMARY KEY,
    name       TEXT NOT NULL,
    address    TEXT NOT NULL DEFAULT '',
    created_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE organizations.memberships (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations.organizations (id),
    user_id         UUID NOT NULL,
    role            TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'invited', 'removed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organization_id, user_id)
);

CREATE TABLE organizations.invitations (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations.organizations (id),
    email           TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
    invited_by      UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- organizations.audit_log (00003, #165) — append-only history for
-- organization/membership/invitation changes. entity_type distinguishes the
-- three entities sharing this table (history.md §3, §9).
CREATE TABLE organizations.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL CHECK (entity_type IN ('organization', 'membership', 'invitation')),
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_fields  TEXT[],
    change          JSONB NOT NULL
);
