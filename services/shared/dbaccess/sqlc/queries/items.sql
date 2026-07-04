-- name: CreateItem :one
INSERT INTO platform_example.items (id, name)
VALUES ($1, $2)
RETURNING id, name, created_at;

-- name: GetItem :one
SELECT id, name, created_at
FROM platform_example.items
WHERE id = $1;

-- name: ListItems :many
SELECT id, name, created_at
FROM platform_example.items
ORDER BY created_at;
