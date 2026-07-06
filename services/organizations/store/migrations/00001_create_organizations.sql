-- +goose Up
-- organizations schema — the tenant root and its memberships (data-model.md
-- §3). The shared auth middleware resolves a user to an active membership
-- here (auth.md §5.1 steps 2–3) to get the request's organization_id + role.
-- Schema created IF NOT EXISTS so integration tests run on a bare Postgres;
-- in-cluster the postgres chart pre-creates it.
CREATE SCHEMA IF NOT EXISTS organizations;

CREATE TABLE organizations.organizations (
    id         UUID PRIMARY KEY,
    name       TEXT NOT NULL,
    address    TEXT NOT NULL DEFAULT '',
    created_by UUID,                             -- soft ref → identity.users (first admin, D-3)
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE organizations.memberships (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations.organizations (id),
    user_id         UUID NOT NULL,               -- soft ref → identity.users (FR-TEN-2)
    role            TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'invited', 'removed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organization_id, user_id)
);

-- Active-membership lookup by user is the hot path the auth middleware runs
-- on (nearly) every request (§4.2).
CREATE INDEX idx_memberships_user_active
    ON organizations.memberships (user_id)
    WHERE status = 'active';

-- +goose Down
DROP TABLE IF EXISTS organizations.memberships;
DROP TABLE IF EXISTS organizations.organizations;
DROP SCHEMA IF EXISTS organizations;
