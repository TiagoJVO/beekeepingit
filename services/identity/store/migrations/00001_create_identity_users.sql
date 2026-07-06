-- +goose Up
-- identity.users — the local projection of a Keycloak-authenticated principal
-- (data-model.md §3). `keycloak_sub` is the OIDC subject (D-7) the shared
-- auth middleware resolves an incoming token to (auth.md §5.1 step 1). The
-- schema is created here (IF NOT EXISTS) so the service's integration tests
-- run against a bare Postgres; in-cluster the postgres chart pre-creates it.
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

-- +goose Down
DROP TABLE IF EXISTS identity.users;
DROP SCHEMA IF EXISTS identity;
