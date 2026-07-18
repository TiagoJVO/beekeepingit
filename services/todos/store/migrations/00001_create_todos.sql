-- +goose Up
-- todos schema — the owning table for #50 (FR-TD-1, FR-TEN-2, EPIC-05 M5).
-- Shape follows the same sync-publication conventions as
-- activities.activities (services/activities/store/migrations/00001_create_activities.sql):
-- client-supplied UUID PK, organization_id on every row (tenancy, FR-TEN-2),
-- created_at/updated_at, deleted_at tombstone. `updated_at` is the device
-- wall-clock LWW comparator; `recorded_at` is the server receive time.
--
-- Unlike activities, todos has NO JSONB attributes bag — every field FR-TD-1
-- names (title/description/due date/priority/assignee) is a plain typed
-- column. `priority` and `status` are deliberately TEXT, not a DB
-- enum/CHECK-constrained set (D-20): the known vocabularies (low/medium/high;
-- open/done) are validated in the OWNING SERVICE (api/types.go), mirroring
-- the data-model.md §2 "extensible enums" convention activities' own `type`
-- column already uses — so extending either vocabulary later is a code-only
-- append, never a schema migration.
--
-- `assignee_id` is a CROSS-SERVICE soft reference to an organizations member
-- (docs/architecture/service-decomposition.md §4 rule 2: "cross-context
-- references are by ID, not FK") — organizations owns its own membership
-- schema, so no FK constraint is possible or desired here. It is OPTIONAL
-- (D-23: "optional assignee_id, default unassigned, assignable/reassignable/
-- clearable") and does NOT gate visibility — every org member can see every
-- org todo regardless of assignee (FR-TEN-2: shared across all org members).
--
-- `completed_at` and `status` are both stored (not derived from one another):
-- `status` is the Go-validated open|done vocabulary; `completed_at` is the
-- timestamp the todo was marked done (cleared on reopen) — kept as its own
-- column since a future "completed in the last N days" query benefits from a
-- real timestamp rather than reconstructing it from audit_log.
--
-- `due_date` is a nullable DATE — a todo may legitimately have none (FR-TD-1).
--
-- NO apiary_id column: apiary association (#51) is explicitly out of scope
-- for #50 and adds its own nullable column in a later migration — this
-- migration deliberately leaves room for that additive change rather than
-- precluding it.
--
-- The `todos` SCHEMA is provisioned by infra (postgres chart bootstrap), not
-- here — the least-privilege per-service role needs no CREATE-on-database
-- right (D-6). Integration tests create it in setup before migrating, same
-- as every other service.
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
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL,               -- device time; LWW comparator
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(), -- server receive time
    deleted_at      TIMESTAMPTZ                         -- soft-delete tombstone (never hard-deleted)
);

-- Org-scoped read path (a todo list, filterable by status/due date — #53's
-- future scope, the index just needs to exist ahead of that story): live
-- rows only, ordered by due date.
CREATE INDEX idx_todos_org_status_due
    ON todos.todos (organization_id, status, due_date)
    WHERE deleted_at IS NULL;

-- "My todos" / per-assignee read path (D-23): live rows with an assignee set.
CREATE INDEX idx_todos_org_assignee
    ON todos.todos (organization_id, assignee_id)
    WHERE deleted_at IS NULL AND assignee_id IS NOT NULL;

-- sync_conflict_log — the LWW safety net (sync.md §4.2), same shape as
-- activities.sync_conflict_log. Co-located in this service's own schema
-- (ownership rule 1).
CREATE TABLE todos.sync_conflict_log (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       UUID NOT NULL,
    winning_payload JSONB NOT NULL,
    losing_payload  JSONB NOT NULL,
    winner          TEXT NOT NULL CHECK (winner IN ('server', 'client')),
    actor_user_id   UUID,
    occurred_at     TIMESTAMPTZ,                    -- device time of the losing edit
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_todos_conflict_org_entity
    ON todos.sync_conflict_log (organization_id, entity_type, entity_id);

-- +goose Down
DROP TABLE IF EXISTS todos.sync_conflict_log;
DROP TABLE IF EXISTS todos.todos;
