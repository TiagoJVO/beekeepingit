# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## `fix/flutter-sync` (client sync-engine code-review fixes)

- **Status:** ready for review — HIGH #1/#2/#3 and MEDIUM #1 fixed with
  passing regression tests; `flutter analyze`/`flutter test` both green.
- **Open finding (not before-merge-blocking, needs a reviewer check in real
  CI):** `flutter test` in this sandbox (WSL2, `/mnt/c` mounted filesystem)
  still logs `[PowerSync] WARNING: ... Multiple instances ...` — 43
  occurrences across the suite, unchanged before/after this PR's fix. Root-
  caused via debug instrumentation: `PowerSyncDatabase.initialize()` itself
  never completes within any `testWidgets` run in this sandbox (neither a
  print placed right after `db.initialize()` nor one inside
  `powerSyncProvider`'s `ref.onDispose` callback ever fires, even after 90+
  real seconds) — so `ref.onDispose` never runs at all for these test-opened
  instances, meaning the warning here is **not** the HIGH #2 async-dispose
  race this PR fixes (verified independently via `TeardownGuard`'s own
  red/green unit tests, `client/test/core/sync/powersync_service_test.dart`).
  It looks like a sandbox/environment characteristic (possibly the WSL2 9p
  filesystem interacting with PowerSync's native SQLite extension loading),
  pre-existing before this PR. **Action for whoever picks this up:** re-run
  `flutter test` on the real CI runner (not this WSL sandbox) and confirm the
  warning is actually gone there; if it still appears in real CI, that's a
  distinct bug worth its own issue — if it doesn't, this note can just be
  pruned.
