-- sqlc's virtual schema for codegen only — mirrors the "up" side of
-- ../migrations/00001_create_journeys.sql and 00002_create_audit_log.sql
-- (no down migration; runtime schema changes only ever happen via goose).
-- Update both files together.
CREATE SCHEMA IF NOT EXISTS journeys;

CREATE TABLE journeys.journeys (
    id                  UUID PRIMARY KEY,
    organization_id     UUID NOT NULL,
    name                TEXT NOT NULL,
    main_activity_type  TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL,
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ
);

CREATE TABLE journeys.journey_plan_items (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    journey_id      UUID NOT NULL REFERENCES journeys.journeys(id) ON DELETE CASCADE,
    apiary_id       UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

CREATE TABLE journeys.sync_conflict_log (
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

CREATE TABLE journeys.audit_log (
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
