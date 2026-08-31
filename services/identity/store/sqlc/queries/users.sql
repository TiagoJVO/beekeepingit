-- name: GetUserByOidcSub :one
SELECT id, oidc_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE oidc_sub = $1;

-- name: GetUserByEmail :one
-- Case-insensitive email -> identity.users lookup, backing the internal
-- GET /internal/users/by-email/{email} endpoint (#468's platform
-- cross-organization membership-lookup support tool, D-7: this stays a
-- LOCAL query against identity's own mirrored profile data -- no new IdP
-- integration). identity.users.email must never be used for anything
-- security-sensitive, and the reason OUTLIVED the one it was written with:
-- it used to be "the free-text field PATCH /v1/profile lets a caller set to
-- anything" (#25/#170), which stopped being true when the address became
-- IdP-owned and read-only (#365 follow-up). It still has NO uniqueness
-- constraint, it is a cache seeded once at first sight, and it is never
-- re-verified against the token afterwards -- so it can be stale, shared, or
-- both. A column that merely stopped being writable is not a reason to start
-- trusting it (see organizations/api/organizations.go's ResolvedUser doc).
-- The earliest-created match wins on the rare chance
-- two profiles share one address, the same "oldest wins" convention
-- organizations' own GetPendingInvitationByEmail uses for its analogous
-- ambiguity. Empty-string emails are excluded explicitly so a blank query
-- can never match every such profile in one row -- still reachable after the
-- seeding change, because the seed is gated on `email_verified`: a caller
-- whose token carries an unverified address is stored with '' exactly as an
-- unseeded row was.
SELECT id, oidc_sub, name, email, locale, created_at, updated_at
FROM identity.users
WHERE email <> '' AND lower(email) = lower(sqlc.arg(email))
ORDER BY created_at
LIMIT 1;

-- name: GetUsersByNames :many
-- Batch resolve app user_ids -> display name, backing the internal
-- GET /internal/users/names endpoint the organizations service composes to
-- turn a member roster (user_ids) into display names (#44 follow-up to
-- per-user attribution, FR-TEN-2). Only rows that exist are returned; a
-- caller treats a missing id as "no name" (a removed or never-provisioned
-- user) and falls back to a short id fragment. Returns name only — never the
-- IdP-verified email: names are org-shareable app data (FR-TEN-2), the email
-- is not.
SELECT id, name
FROM identity.users
WHERE id = ANY(@ids::uuid[]);

-- name: UpsertUserOnFirstSeen :one
-- Get-or-create on first authenticated profile read (#25, FR-ONB-1): if no row
-- exists yet for oidc_sub, insert one SEEDED from the caller's verified token
-- claims (#365 follow-up) — the provider already knows the user's name and
-- address, so onboarding must not ask them to retype it. A provider that
-- emits no name seeds '' and the client still prompts; the email is seeded
-- only when the token says it is verified, so an unverified address never
-- enters the cache.
--
-- The ON CONFLICT branch is a no-op update (bumps nothing semantically —
-- updated_at is reassigned to itself) purely so RETURNING gives back the
-- existing row. That no-op is now load-bearing in a second way: it is what
-- makes "seed once, never re-sync" STRUCTURAL rather than merely intended —
-- the seed values are deliberately ignored on conflict, so a later login can
-- never overwrite a name the user has since edited.
INSERT INTO identity.users (id, oidc_sub, name, email, locale)
VALUES ($1, $2, sqlc.arg(name), sqlc.arg(email), 'en')
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
