-- sqlc's virtual schema for codegen only — NOT a bootstrap baseline, and never
-- applied to a database. It mirrors the cumulative "up" state of ../migrations/,
-- which since #541's squash is the single 00006_baseline.sql (plus any migration
-- added after it).
--
-- Keep in sync BY HAND when a migration changes a shape sqlc generates from. The
-- migrations are the real schema; this file only teaches sqlc the column types, so
-- drift surfaces as wrong generated Go types rather than as a failed migration —
-- which is exactly why it is worth stating here.

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
-- three entities sharing this table (history.md §3, §9). actor_scope (00005,
-- #470) distinguishes an ordinary member/admin write from a verified
-- platform-operator write (ADR-0021) -- see 00005's migration comment.
CREATE TABLE organizations.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL CHECK (entity_type IN ('organization', 'membership', 'invitation')),
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,
    actor_scope     TEXT NOT NULL DEFAULT 'member' CHECK (actor_scope IN ('member', 'platform_operator')),
    occurred_at     TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_fields  TEXT[],
    change          JSONB NOT NULL
);
