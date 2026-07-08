# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging `feat/EPIC-01-members-nav-link` (#172)

- **No local Go/Flutter toolchain in this environment**: `services/organizations/api/organizations.go`,
  its tests, `contracts/openapi/organizations.openapi.yaml`, and the Dart changes (including hand-updated
  `l10n/gen/` output) were written carefully against existing conventions but never compiled, vetted, or
  run locally. CI (`ci.yml`'s repo-wide `task ci`, `build-publish.yml`'s `services-organizations`/`client`
  matrix, and `contracts-ci.yml`'s OpenAPI breaking-change gate) is the first real
  compile/test/lint/contract-diff pass. **Check all are green before merging.** Prune this entry once
  they've passed on the PR.
