-- +goose Up
-- todos.todos.apiary_id (#51, FR-TD-1) — optional soft reference to the
-- specific apiary a todo relates to; NULL means a general, org-level todo
-- (FR-TD-1: "may be associated with a specific apiary, or left as a general,
-- org-level todo"). No FK — cross-context references are by ID, not FK
-- (docs/architecture/service-decomposition.md §4 rule 2); todos has no
-- database access to the apiaries schema (ownership rule 1), so every write
-- path that sets this column verifies it against the apiaries service itself
-- (api/apiaries_client.go's ApiaryVerifier, GET /v1/apiaries/{id}) before
-- writing anything — mirroring activities' own apiary_id guard
-- (activities/api/apiaries_client.go, live since #38).
--
-- Apiary deletion (apiaries never hard-deletes, tombstone via deleted_at):
-- there is NO active reconciliation here that clears apiary_id when its
-- apiary is later deleted — mirroring activities' own precedent for
-- apiary_id (no clear-on-delete mechanism exists there either). A todo whose
-- apiary_id no longer resolves to a live apiary is tolerated at READ time
-- only (client-side renders it as unassociated / "apiary unavailable" —
-- never crashes, never shows broken data); the apiary's own deletion is
-- already recorded in apiaries.audit_log, so no history is lost. See
-- services/todos/README.md's "apiary association" section for the full
-- rationale.
ALTER TABLE todos.todos ADD COLUMN apiary_id UUID NULL;

-- Org-scoped read path (a future "todos for apiary X" list/filter, #53's
-- scope — the index just needs to exist ahead of that story): live rows
-- with an apiary set, mirroring idx_todos_org_assignee's own shape
-- (00001_create_todos.sql).
CREATE INDEX idx_todos_org_apiary
    ON todos.todos (organization_id, apiary_id)
    WHERE deleted_at IS NULL AND apiary_id IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS todos.idx_todos_org_apiary;
ALTER TABLE todos.todos DROP COLUMN IF EXISTS apiary_id;
