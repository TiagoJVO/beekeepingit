-- name: GetUserByKeycloakSub :one
SELECT id, keycloak_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE keycloak_sub = $1;

-- name: GetUserByID :one
SELECT id, keycloak_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE id = $1;

-- name: UpsertUserOnFirstSeen :one
-- Get-or-create on first authenticated profile read (#25, FR-ONB-1): if no row
-- exists yet for keycloak_sub, insert one with empty name/email so the client
-- can detect an incomplete profile and prompt onboarding. The ON CONFLICT
-- branch is a no-op update (bumps nothing semantically — updated_at is
-- reassigned to itself) purely so RETURNING gives back the existing row.
INSERT INTO identity.users (id, keycloak_sub, name, email, locale)
VALUES ($1, $2, '', '', 'en')
ON CONFLICT (keycloak_sub) DO UPDATE SET updated_at = identity.users.updated_at
RETURNING id, keycloak_sub, name, email, locale, created_at, updated_at;

-- name: UpdateUserProfile :one
-- Partial update backing PATCH /v1/profile: each column is set to the
-- provided value only when its companion `set_x` flag is true, otherwise it
-- keeps the current value (COALESCE-free — sqlc's CASE form makes an
-- all-optional partial update explicit at the call site).
UPDATE identity.users
SET name       = CASE WHEN sqlc.arg(set_name)::bool THEN sqlc.arg(name) ELSE name END,
    email      = CASE WHEN sqlc.arg(set_email)::bool THEN sqlc.arg(email) ELSE email END,
    locale     = CASE WHEN sqlc.arg(set_locale)::bool THEN sqlc.arg(locale) ELSE locale END,
    updated_at = now()
WHERE keycloak_sub = sqlc.arg(keycloak_sub)
RETURNING id, keycloak_sub, name, email, locale, created_at, updated_at;
