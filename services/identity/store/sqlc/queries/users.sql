-- name: GetUserByKeycloakSub :one
SELECT id, keycloak_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE keycloak_sub = $1;

-- name: GetUserByID :one
SELECT id, keycloak_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE id = $1;
