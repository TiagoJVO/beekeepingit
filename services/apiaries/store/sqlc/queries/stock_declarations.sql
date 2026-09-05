-- name: GetStockDeclarationForUpdate :one
-- Row-locking read for the sync-apply path (#298, FR-AP-10): SELECT ... FOR
-- UPDATE so the LWW timestamp comparison and the write that follows are atomic
-- against a concurrent apply of the same declaration. Mirrors
-- GetApiaryForUpdate exactly — unlike apiary_counters (whose identity is
-- (apiary_id, counter_type), not its row id), a declaration IS identified by
-- its own client-generated id, so this is a plain PK lookup under org scope.
SELECT id, organization_id, registration_number, declared_on,
       total_hive_count, breakdown, notes, created_at, updated_at, deleted_at
FROM apiaries.stock_declarations
WHERE organization_id = $1 AND id = $2
FOR UPDATE;

-- name: InsertStockDeclaration :exec
-- Sync-apply create (#298). Every column set explicitly, including deleted_at,
-- so an offline create and an offline create-then-delete replayed in one batch
-- both land correctly — the same full-row shape InsertApiary uses.
INSERT INTO apiaries.stock_declarations (
    id, organization_id, registration_number, declared_on,
    total_hive_count, breakdown, notes, updated_at, deleted_at
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: UpdateStockDeclaration :exec
-- Sync-apply update (#298): the caller computes the full desired row first
-- (sync.go's mergeDeclarationOp), so this always sets every mutable column,
-- matching UpdateApiary. recorded_at is bumped to server-now, the ingestion
-- stamp the history/conflict log correlates against (history.md §3).
UPDATE apiaries.stock_declarations
SET registration_number = $3,
    declared_on = $4,
    total_hive_count = $5,
    breakdown = $6,
    notes = $7,
    updated_at = $8,
    deleted_at = $9,
    recorded_at = now()
WHERE organization_id = $1 AND id = $2;
