-- name: CreateOrganization :one
-- Creates the org (FR-ONB-2). Paired with CreateMembership in the same DB
-- transaction (api/organizations.go) so the creator's admin membership is
-- never observable without its org, or vice versa (D-3).
INSERT INTO organizations.organizations (id, name, address, created_by)
VALUES ($1, $2, $3, $4)
RETURNING id, name, address, created_by, created_at, updated_at;
