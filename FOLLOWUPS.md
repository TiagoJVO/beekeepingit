# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging `feat/EPIC-01-account-settings` (#29)

- **No local Go/Flutter toolchain in this sandbox** (still true as of #29): `go`, `sqlc`, and
  `flutter` are not installed in the environment this branch was authored in. #29 itself adds
  no new backend routes/sqlc queries (account settings reuses #25's existing
  `GET`/`PATCH /v1/profile` as-is) and no new Dart dependency (Keycloak's Account Console
  redirect uses `package:web`, already a dependency), so the blast radius is smaller than #25/
  #27's — but `flutter analyze`/`flutter test` still could not be run locally for the new
  `client/lib/features/account/` files, `app_router.dart`, `apiaries_list_screen.dart`, and the
  new/changed test files. CI (`build-publish.yml`'s `client` component build) is the first real
  compile/test — **check that it's green before merging**. Prune this entry once CI has passed
  on the PR.
- History recording (FR-HIS-1) for profile updates made from the account settings screen is
  intentionally not implemented — same deferred seam as #25/#26/#27, tracked in
  [#165](https://github.com/TiagoJVO/beekeepingit/issues/165); the corresponding AC checkbox on
  #29 is left unchecked. Prune this line once #165 lands (no action needed on #29 itself before
  merging — both paths already go through the same `PATCH /v1/profile`, so #165's fix covers
  this screen automatically once it lands there).
