-- name: GetUserByOidcSub :one
SELECT id, oidc_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE oidc_sub = $1;

-- name: UpsertUserOnFirstSeen :one
-- Get-or-create on first authenticated profile read (#25, FR-ONB-1): if no row
-- exists yet for oidc_sub, insert one with empty name/email so the client
-- can detect an incomplete profile and prompt onboarding. The ON CONFLICT
-- branch is a no-op update (bumps nothing semantically — updated_at is
-- reassigned to itself) purely so RETURNING gives back the existing row.
INSERT INTO identity.users (id, oidc_sub, name, email, locale)
VALUES ($1, $2, '', '', 'en')
ON CONFLICT (oidc_sub) DO UPDATE SET updated_at = identity.users.updated_at
RETURNING id, oidc_sub, name, email, locale, created_at, updated_at;

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
WHERE oidc_sub = sqlc.arg(oidc_sub)
RETURNING id, oidc_sub, name, email, locale, created_at, updated_at;

-- name: InsertAuditLog :exec
-- Append-only history row (history.md §3-§4, #165): one row per applied
-- profile create/update, written in the same local transaction as the
-- domain write. organization_id is always NULL (identity.users is global,
-- history.md §9). changed_fields is null for create (only update carries
-- it).
INSERT INTO identity.audit_log
    (id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, changed_fields, change)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: ListAuditLog :many
-- The per-entity timeline read (FR-HIS-1, history.md §8): every history row
-- for one entity, oldest first. Not yet exposed via HTTP (no AC in this
-- milestone requires the view screens, history.md §8/§10) — kept as typed
-- groundwork for the profile-detail "history" screen.
SELECT id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
FROM identity.audit_log
WHERE entity_type = $1 AND entity_id = $2
ORDER BY recorded_at, id;
