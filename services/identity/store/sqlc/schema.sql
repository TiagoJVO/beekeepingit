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
