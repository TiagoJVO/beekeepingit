-- +goose Up
-- Provider-neutral rename: the OIDC subject column is named for the standard
-- claim (`sub`) it projects, not for whichever IdP happens to issue it
-- (Keycloak→Authentik migration, docs/architecture/oidc-integration.md §6). The
-- app depends only on standard OIDC (§1), so nothing here is Authentik-specific;
-- the column keeps its value, type and UNIQUE constraint — only the name changes.
ALTER TABLE identity.users RENAME COLUMN keycloak_sub TO oidc_sub;

-- +goose Down
ALTER TABLE identity.users RENAME COLUMN oidc_sub TO keycloak_sub;
