-- sqlc's virtual schema for codegen only — NOT a bootstrap baseline, and never
-- applied to a database. It mirrors the cumulative "up" state of ../migrations/,
-- which since #541's squash is the single 00004_baseline.sql (plus any migration
-- added after it).
--
-- Keep in sync BY HAND when a migration changes a shape sqlc generates from. The
-- migrations are the real schema; this file only teaches sqlc the column types, so
-- drift surfaces as wrong generated Go types rather than as a failed migration —
-- which is exactly why it is worth stating here.

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
