-- sqlc's virtual schema for codegen only — mirrors the CUMULATIVE "up" state of
-- ../migrations/*.sql (kept separate because sqlc applies files sequentially and
-- would otherwise also "see" a down migration's DROP). It reflects the schema
-- AFTER all migrations, so `oidc_sub` here is the post-rename name (00002
-- renames the column the 00001 create introduced — see those files). Runtime
-- schema changes only ever happen via goose; update this file with each migration.
CREATE SCHEMA IF NOT EXISTS identity;

CREATE TABLE identity.users (
    id           UUID PRIMARY KEY,
    oidc_sub     TEXT NOT NULL UNIQUE,
    name         TEXT NOT NULL DEFAULT '',
    email        TEXT NOT NULL DEFAULT '',
    locale       TEXT NOT NULL DEFAULT 'en',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- identity.audit_log (00003, #165) — append-only profile change history.
-- organization_id is nullable (unlike apiaries.audit_log): identity.users is
-- global, not org-owned (history.md §9), so it's always NULL here.
CREATE TABLE identity.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_fields  TEXT[],
    change          JSONB NOT NULL
);
