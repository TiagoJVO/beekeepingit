# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging `feat/EPIC-01-profile-onboarding` (#25)

- **No local Go/Flutter toolchain in this sandbox**: `go`, `sqlc`, and `flutter` are not
  installed in the environment this branch was authored in, so
  `services/identity/store/sqlc/gen/users.sql.go`'s two new queries
  (`UpsertUserOnFirstSeen`, `UpdateUserProfile`) were **hand-written** to match `sqlc
generate`'s output conventions rather than generated, and `go test`/`go vet`/`flutter
analyze`/`flutter test` could not be run locally. CI (`build-publish.yml`'s per-component
  matrix, which covers both `services/identity` and `client` since each has a Dockerfile/
  pubspec.yaml) is the first real compile/test of this code — **check that it's green before
  merging**, and if `sqlc generate` output differs from the hand-written file, regenerate it
  for real and commit the diff. Prune this entry once CI has passed on the PR.
- History recording (FR-HIS-1) for profile create/update is intentionally not implemented —
  tracked in [#165](https://github.com/TiagoJVO/beekeepingit/issues/165); the corresponding AC
  checkbox on #25 is left unchecked. Prune this line once #165 lands and profile writes are
  wired to it (no action needed on #25 itself before merging).
