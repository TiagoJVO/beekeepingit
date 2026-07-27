-- name: InsertTodo :one
-- Creates one todo row, org-scoped (FR-TEN-2, FR-TD-1). `priority`/`status`
-- are the caller's already-validated (api/types.go's IsKnownPriority/
-- IsKnownStatus, D-20) vocabulary values — this query never re-validates
-- them, matching the activities convention that the DB layer trusts the API
-- layer's validation pass. `assignee_id` (D-23) must already have been
-- ownership-verified against the organizations service (api/members_client.go)
-- before this runs; `apiary_id` (#51) must already have been
-- ownership-verified against the apiaries service (api/apiaries_client.go)
-- the same way.
INSERT INTO todos.todos
    (id, organization_id, title, description, due_date, priority, status, assignee_id, apiary_id, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
RETURNING id, organization_id, title, description, due_date, priority, status, completed_at,
          assignee_id, apiary_id, created_at, updated_at, recorded_at, deleted_at;

-- name: GetTodo :one
-- Org-scoped single-row read (never a client-supplied organization_id —
-- api/common.go's requireOrg pattern, mirrored from activities).
SELECT id, organization_id, title, description, due_date, priority, status, completed_at,
       assignee_id, apiary_id, created_at, updated_at, recorded_at, deleted_at
FROM todos.todos
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: GetTodoForUpdate :one
-- Locks the row (or reports its absence, including a soft-deleted one) for
-- the REST update/complete/reopen/delete transaction and the sync-apply LWW
-- compare (mirrors activities' GetActivityForUpdate). No deleted_at filter —
-- callers explicitly check the returned row's deleted_at: REST 404s a
-- tombstoned row, while sync-apply's LWW still applies OVER a tombstone (a
-- strictly-newer offline edit can legitimately "undelete" the row).
SELECT id, organization_id, title, description, due_date, priority, status, completed_at,
       assignee_id, apiary_id, created_at, updated_at, recorded_at, deleted_at
FROM todos.todos
WHERE organization_id = $1 AND id = $2
FOR UPDATE;

-- name: UpdateTodo :one
-- REST update (PATCH /v1/todos/{id}, FR-TD-1): a FULL resubmit of
-- title/description/due_date/priority/assignee_id/apiary_id — the caller
-- computes the full desired row first, so this always sets every one of
-- those columns. status/completed_at are NEVER written here — the
-- complete/reopen routes own that transition exclusively (CompleteTodo/
-- ReopenTodo below). WHERE deleted_at IS NULL is defense-in-depth — the
-- handler already 404s a tombstoned row via its own GetTodoForUpdate check
-- before reaching here.
UPDATE todos.todos
SET title = $3, description = $4, due_date = $5, priority = $6, assignee_id = $7, apiary_id = $8, updated_at = $9, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL
RETURNING id, organization_id, title, description, due_date, priority, status, completed_at,
          assignee_id, apiary_id, created_at, updated_at, recorded_at, deleted_at;

-- name: CompleteTodo :one
-- POST /v1/todos/{id}/complete: sets status='done' + completed_at, bumping
-- updated_at to the same timestamp (the LWW comparator) — idempotent if the
-- todo is already done (re-running this just refreshes completed_at/updated_at,
-- which is fine: the REST route itself decides whether that's worth doing;
-- this query has no side effect beyond the plain column set).
UPDATE todos.todos
SET status = 'done', completed_at = $3, updated_at = $3, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL
RETURNING id, organization_id, title, description, due_date, priority, status, completed_at,
          assignee_id, apiary_id, created_at, updated_at, recorded_at, deleted_at;

-- name: ReopenTodo :one
-- POST /v1/todos/{id}/reopen: sets status='open' and clears completed_at.
UPDATE todos.todos
SET status = 'open', completed_at = NULL, updated_at = $3, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL
RETURNING id, organization_id, title, description, due_date, priority, status, completed_at,
          assignee_id, apiary_id, created_at, updated_at, recorded_at, deleted_at;

-- name: SoftDeleteTodo :execrows
-- REST delete (DELETE /v1/todos/{id}): tombstone, matching the sync path's
-- deleted_at convention so the delete propagates to devices (FR-OF-1) — the
-- PowerSync Sync Rules filter deleted_at IS NULL
-- (infra/helm/beekeepingit/charts/powersync/values.yaml). :execrows so the
-- caller can distinguish "already gone" (0 rows) from success without a
-- separate SELECT, mirroring activities' SoftDeleteActivity.
UPDATE todos.todos
SET deleted_at = $3, updated_at = $3, recorded_at = now()
WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL;

-- name: UpdateTodoSync :exec
-- Sync-apply put/patch/delete: sets every mutable column, INCLUDING
-- status/completed_at/deleted_at (a tombstone is just another LWW-compared
-- field, sync.md §4.5) — the caller (applyTodoOp's mergeTodoOp) computes the
-- full desired row first. Mirrors activities' UpdateActivitySync.
UPDATE todos.todos
SET title = $3, description = $4, due_date = $5, priority = $6, status = $7, completed_at = $8,
    assignee_id = $9, apiary_id = $10, updated_at = $11, deleted_at = $12, recorded_at = now()
WHERE organization_id = $1 AND id = $2;

-- name: InsertAuditLog :exec
-- Append-only history row (history.md §3-§4, FR-HIS-1), mirroring
-- activities.audit_log's own InsertAuditLog query. changed_fields is null
-- for create/delete.
INSERT INTO todos.audit_log
    (id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, changed_fields, change)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: ListAuditLog :many
-- The per-entity timeline read (FR-HIS-1) — not yet exposed via HTTP (no AC
-- in this milestone requires the view screens), kept as typed groundwork for
-- the entity-detail "history" screen, mirroring activities.ListAuditLog.
SELECT id, organization_id, entity_type, entity_id, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
FROM todos.audit_log
WHERE organization_id = $1 AND entity_type = $2 AND entity_id = $3
ORDER BY recorded_at, id;

-- name: InsertConflict :exec
-- The LWW safety net (sync.md §4.2), mirroring activities.sync_conflict_log's
-- own InsertConflict query.
INSERT INTO todos.sync_conflict_log
    (id, organization_id, entity_type, entity_id, winning_payload, losing_payload, winner, actor_user_id, occurred_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);
