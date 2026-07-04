-- +goose Up
CREATE SCHEMA IF NOT EXISTS platform_example;

CREATE TABLE platform_example.items (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE IF EXISTS platform_example.items;
DROP SCHEMA IF EXISTS platform_example;
