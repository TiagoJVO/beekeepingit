-- name: CreateOrganization :one
-- Creates the org (FR-ONB-2). Paired with CreateMembership in the same DB
-- transaction (api/organizations.go) so the creator's admin membership is
-- never observable without its org, or vice versa (D-3).
INSERT INTO organizations.organizations (id, name, address, created_by)
VALUES ($1, $2, $3, $4)
RETURNING id, name, address, registration_number, created_by, created_at, updated_at;

-- name: GetOrganizationForUpdate :one
-- Row-locking read for the PATCH path (#289): SELECT ... FOR UPDATE so the
-- If-Match version check and the subsequent UpdateOrganization run atomically
-- against a concurrent writer. A second PATCH blocks here until the first
-- commits, then observes the bumped updated_at, so its stale If-Match is
-- rejected with 409 rather than silently clobbering (optimistic concurrency,
-- FR-TEN-2). Mirrors apiaries' GetApiaryForUpdate.
SELECT id, name, address, registration_number, created_by, created_at, updated_at
FROM organizations.organizations
WHERE id = $1
FOR UPDATE;

-- name: UpdateOrganization :one
-- Applies an admin's org-detail edit (PATCH /organizations/{orgId}, #289,
-- FR-ONB-2). Sets every mutable column plus updated_at (the LWW/ETag version
-- stamp, data-model.md §4.3) explicitly. Scoped by PK; the handler has already
-- asserted the caller is an admin of exactly this org (ADR-0002, NFR-ROL-1).
UPDATE organizations.organizations
SET name = $2,
    address = $3,
    registration_number = $4,
    updated_at = $5
WHERE id = $1
RETURNING id, name, address, registration_number, created_by, created_at, updated_at;

-- name: ListOrganizations :many
-- Platform-operator-only cross-org list (#467, D-32, FR-TEN-2, NFR-ROL-1):
-- the ONE query in this file (indeed, in this service) that deliberately has
-- NO organization_id scope -- every other query here is org-scoped because
-- every other caller is confined to their own org (ADR-0002); this one backs
-- the platform console's "enumerate every tenant" screen, gated entirely at
-- the handler by isPlatformOperator (api/organizations.go's listOrganizations),
-- never by this query itself.
--
-- Keyset-paginated by id DESC (newest org first) -- matches ListMembers'/
-- ListInvitations' own id-DESC convention in this same service (memberships.sql,
-- invitations.sql), not apiaries' id-ASC (a different service's convention).
--
-- q (optional, #467 AC "search/filter by name"): a case-insensitive ILIKE
-- substring match on name. The caller-supplied query is turned into an
-- escaped `%...%` pattern in Go (api/organizations.go's likeSearchPattern)
-- before reaching here, so a literal %, _ or \ in the search text is matched
-- literally, not as a wildcard -- this query only ever sees an
-- already-escaped pattern plus the ESCAPE '\' clause that makes the escaping
-- effective.
--
-- member_count (#467 AC "no member PII... maybe member count"): a
-- COALESCE'd LEFT JOIN aggregate over ACTIVE memberships only, mirroring
-- apiaries' hive_count LEFT JOIN convention (apiaries.sql) -- one join over
-- the page, not one query per row (avoiding N+1). This is the only
-- member-related fact exposed here; no user_id/role/status/email leaves this
-- query, keeping the response a pure organization summary (#467 AC "the
-- response exposes only what the console needs").
SELECT o.id, o.name, o.created_at, o.updated_at,
       COALESCE(mc.member_count, 0)::bigint AS member_count
FROM organizations.organizations o
LEFT JOIN (
    SELECT organization_id, count(*) AS member_count
    FROM organizations.memberships
    WHERE status = 'active'
    GROUP BY organization_id
) mc ON mc.organization_id = o.id
WHERE (sqlc.narg('cursor')::uuid IS NULL OR o.id < sqlc.narg('cursor')::uuid)
  AND (sqlc.narg('q')::text IS NULL OR o.name ILIKE sqlc.narg('q')::text ESCAPE '\')
ORDER BY o.id DESC
LIMIT $1;
