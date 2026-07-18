-- sqlc's virtual schema for codegen only — mirrors the "up" side of
-- ../migrations/00001_create_todos.sql, 00002_create_audit_log.sql and
-- 00003_add_apiary_id.sql (no down migration; runtime schema changes only
-- ever happen via goose). Update all files together.
CREATE SCHEMA IF NOT EXISTS todos;

CREATE TABLE todos.todos (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    due_date        DATE,
    priority        TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open',
    completed_at    TIMESTAMPTZ,
    assignee_id     UUID,
    apiary_id       UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

CREATE TABLE todos.sync_conflict_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    winning_payload JSONB NOT NULL,
    losing_payload  JSONB NOT NULL,
    winner          TEXT NOT NULL CHECK (winner IN ('server', 'client')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE todos.audit_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    change_type     TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'delete')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_fields  TEXT[],
    change          JSONB NOT NULL
);
