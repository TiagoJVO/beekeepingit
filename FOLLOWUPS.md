# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## `feat/EPIC-05-todo-apiary-association` (#51)

- **What**: `services/todos/store/sqlc/gen/{models.go,todos.sql.go}` were
  hand-edited to add the `apiary_id` column/param (matching the updated
  `store/sqlc/queries/todos.sql`/`schema.sql`) because `sqlc` isn't
  available in this sandbox to actually run `sqlc generate`.
- **Why**: the generated-code shape (struct fields, positional `$N`
  placeholders, `Scan`/exec argument order) must match sqlc v1.31.1's own
  output byte-for-byte, or a real Postgres run would fail/mis-bind at
  runtime despite compiling.
- **Where**: `services/todos/store/sqlc/gen/models.go`,
  `services/todos/store/sqlc/gen/todos.sql.go`.
- **Status**: before merge, run `sqlc generate -f store/sqlc/sqlc.yaml`
  (from `services/todos`) in an environment with the `sqlc` CLI and confirm
  the diff against this PR's hand-written version is empty (or apply
  whatever the real generator produces) — CI's `go build`/`go test` will
  also catch any mismatch that fails to compile, but a silent
  argument-order mismatch that still compiles would not be.
