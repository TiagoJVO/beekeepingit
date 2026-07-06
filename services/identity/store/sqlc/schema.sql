-- sqlc's virtual schema for codegen only — mirrors the "up" side of
-- ../migrations/00001_create_identity_users.sql (kept separate because sqlc
-- applies files sequentially and would otherwise also "see" the down
-- migration's DROP). Runtime schema changes only ever happen via goose;
-- update both files together.
CREATE SCHEMA IF NOT EXISTS identity;

CREATE TABLE identity.users (
    id           UUID PRIMARY KEY,
    keycloak_sub TEXT NOT NULL UNIQUE,
    name         TEXT NOT NULL DEFAULT '',
    email        TEXT NOT NULL DEFAULT '',
    locale       TEXT NOT NULL DEFAULT 'en',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
