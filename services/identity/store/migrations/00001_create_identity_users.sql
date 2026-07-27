-- +goose Up
-- identity.users — the local projection of an OIDC-authenticated principal
-- (data-model.md §3). `keycloak_sub` is the OIDC subject (D-7) the shared
-- auth middleware resolves an incoming token to (auth.md §5.1 step 1).
-- NOTE: `keycloak_sub` is renamed to the provider-neutral `oidc_sub` in
-- 00002 (Keycloak→Authentik migration); this file is left as the historical
-- create so the migration chain still replays cleanly.
--
-- The `identity` SCHEMA is provisioned by infra, not here: the postgres chart
-- creates it at bootstrap (owned by the app role), so the least-privilege
-- per-service role (D-6) needs no CREATE-on-database right. Integration tests
-- create it in their setup before migrating (see main_test.go).
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
