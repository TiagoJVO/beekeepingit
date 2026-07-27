-- name: InsertAuditLog :exec
-- Append-only history row (history.md §3-§4, #165): one row per applied
-- organization/membership/invitation create/update, written in the same
-- local transaction as the domain write. changed_fields is null for create
-- (only update carries it). actor_scope (#470, ADR-0021) is written
-- explicitly by every caller -- 'member' for the ordinary membership path,
-- 'platform_operator' for a verified platform-operator write -- never left
-- to the column's DEFAULT (api/audit.go's writeAuditLog).
INSERT INTO organizations.audit_log
    (id, organization_id, entity_type, entity_id, change_type, actor_user_id, actor_scope, occurred_at, changed_fields, change)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);

-- name: ListAuditLog :many
-- The per-entity timeline read (FR-HIS-1, history.md §8): every history row
-- for one entity, oldest first. Not yet exposed via HTTP (no AC in this
-- milestone requires the view screens, history.md §8/§10) — kept as typed
-- groundwork for the org/member/invitation-detail "history" screen.
-- actor_scope (#470) is included so a future history view can render the
-- platform-operator distinction without a second query.
SELECT id, organization_id, entity_type, entity_id, change_type, actor_user_id, actor_scope, occurred_at, recorded_at, changed_fields, change
FROM organizations.audit_log
WHERE organization_id = $1 AND entity_type = $2 AND entity_id = $3
ORDER BY recorded_at, id;
