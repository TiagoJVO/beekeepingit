# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging `feat/EPIC-01-tenancy-check-adoption` (#175)

- **No local Go toolchain in this environment**: the two new schema tests
  (`services/identity/main_test.go`'s `TestIdentitySchema_UsersIsTheDocumentedTenancyException`,
  `services/organizations/main_test.go`'s
  `TestOrganizationsSchema_OrganizationsIsTheDocumentedTenancyException`) were written carefully
  against the existing `dbaccess.UnscopedTables` adoption pattern (`services/apiaries/main_test.go`,
  #30) but never compiled or run locally. CI (`ci.yml`'s repo-wide `task ci`) is the first real
  compile/test pass. **Check it's green before merging.** Prune this entry once it has passed on
  the PR.
