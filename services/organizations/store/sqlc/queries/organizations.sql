-- name: CreateOrganization :one
-- Creates the org (FR-ONB-2). Paired with CreateMembership in the same DB
-- transaction (api/organizations.go) so the creator's admin membership is
-- never observable without its org, or vice versa (D-3).
INSERT INTO organizations.organizations (id, name, address, created_by)
VALUES ($1, $2, $3, $4)
RETURNING id, name, address, created_by, created_at, updated_at;

-- name: GetOrganizationForUpdate :one
-- Row-locking read for the PATCH path (#289): SELECT ... FOR UPDATE so the
-- If-Match version check and the subsequent UpdateOrganization run atomically
-- against a concurrent writer. A second PATCH blocks here until the first
-- commits, then observes the bumped updated_at, so its stale If-Match is
-- rejected with 409 rather than silently clobbering (optimistic concurrency,
-- FR-TEN-2). Mirrors apiaries' GetApiaryForUpdate.
SELECT id, name, address, created_by, created_at, updated_at
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
    updated_at = $4
WHERE id = $1
RETURNING id, name, address, created_by, created_at, updated_at;
