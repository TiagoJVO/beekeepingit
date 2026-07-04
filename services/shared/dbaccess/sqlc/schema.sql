-- sqlc's virtual schema for codegen only — mirrors the "up" side of
-- ../migrations/00001_create_example_items.sql (kept separate because sqlc
-- applies migration files sequentially and would otherwise "see" the down
-- migration's DROP TABLE too). Runtime schema changes only ever happen via
-- goose; update both files together.
CREATE SCHEMA IF NOT EXISTS platform_example;

CREATE TABLE platform_example.items (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
