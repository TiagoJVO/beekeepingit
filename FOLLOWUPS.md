# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

(#51's own hand-written-sqlc verification note is resolved: that PR already
merged, and CI's containerized-Postgres integration tests — plus an
independent code-reviewer and security-reviewer pass — confirmed the
generated code binds/scans correctly at runtime, not just compiles.)

(#293's own no-local-toolchain note is resolved: CI's `dart lint`/`dart
l10n-check` ran for real — ARB key parity and the hand-edited
`lib/l10n/gen/*` output both passed with no drift; `flutter analyze` caught
two genuine `unused_element_parameter` warnings (`throwOnReopen` declared
but never set to `true` by any test), fixed by adding the missing
reopen-failure test case both files were otherwise structured for.)

## Not covered by an automated test: `todo_form_screen.dart`'s date picker

- **What**: actually driving the real `showDatePicker` calendar UI to pick a
  _new_ due date — only the pre-fill/display and the clear-button path are
  tested.
- **Why**: no existing precedent in this codebase for testing that
  interaction (`add_activity_screen.dart`'s own `occurredAt` date field is
  the same shape and isn't UI-driven in its own tests either).
- **Status**: not blocking; a reviewer wanting this covered should add it as
  a follow-up.
