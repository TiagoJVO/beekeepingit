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

## Before merge: `feat/EPIC-05-todo-detail-form` (#293)

- **No local Flutter/Dart toolchain was available** in the session that
  built this branch (`flutter`/`dart` not on `PATH`) — `flutter analyze`,
  `flutter test`, and `flutter gen-l10n` could not be run locally. All new
  Dart source was hand-reviewed for correctness (imports, provider wiring,
  key names, lint conventions) and a manual brace/paren-balance + ARB
  JSON-validity/key-parity check was run via Node, but **CI's `dart lint`,
  `dart test`, and `dart l10n-check` (`taskfiles/dart.yml`) are this
  branch's real, unexercised gate** — check their run before merging.
- `client/lib/l10n/gen/{app_localizations.dart,app_localizations_en.dart,
  app_localizations_pt.dart}` were hand-edited to mirror `flutter
  gen-l10n`'s usual output style (new todo detail/form keys), since the
  generator itself couldn't be run. `l10n-check`'s `git diff --exit-code`
  step will catch any byte-for-byte drift from a real regeneration — if it
  fails, run `flutter gen-l10n` in `client/` and commit the regenerated
  output (the ARB source is already correct/validated; only the committed
  `gen/` output is at risk of a formatting mismatch).
- Deliberately **not covered by an automated test**: actually driving
  `todo_form_screen.dart`'s real `showDatePicker` calendar UI to pick a
  *new* due date (only pre-fill/display and the clear-button path are
  tested) — this codebase has no existing precedent for testing that
  interaction (add_activity_screen.dart's own `occurredAt` date field is
  the same shape and isn't UI-driven in its tests either), and simulating
  it without a working local Flutter toolchain to verify the exact
  MaterialDatePicker widget tree risked a flaky test. A reviewer wanting
  this covered should add it as a follow-up, not block this PR on it.
