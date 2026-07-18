# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## `feat/EPIC-05-todo-model-lifecycle` (#50)

- **What**: `infra/helm/beekeepingit/charts/postgres/values.yaml`'s
  `syncedSchemas` now includes `todos`, but the `powersync` publication is
  created ONCE, at cluster bootstrap, by `postInitApplicationSQL`'s
  `CREATE PUBLICATION ... FOR TABLES IN SCHEMA` (`cluster.yaml`) — adding a
  schema to the values file only takes effect on a FRESH bootstrap.
- **Why**: an already-running cluster's `powersync` publication needs a
  one-time `ALTER PUBLICATION powersync ADD TABLES IN SCHEMA todos;` run by
  hand before todo rows will actually replicate to devices (the `powersync`
  role's membership in `todos_svc`, by contrast, IS continuously reconciled
  by CNPG's `managed.roles` and self-heals).
- **Where**: `infra/helm/beekeepingit/charts/postgres/values.yaml` (comment
  left in place), `infra/helm/beekeepingit/charts/postgres/templates/cluster.yaml`.
- **Status**: not blocking for CI/merge (helm lint/template only); the dev
  cluster is currently torn down/rebuilt from scratch via `infra/cluster`
  scripts, which re-bootstraps and picks this up automatically. Only
  relevant the first time this reaches a cluster that is bootstrapped and
  kept running rather than rebuilt — run the `ALTER PUBLICATION` manually
  then, or fold it into a migration/bootstrap job if that becomes routine
  (`EPIC-13`/infra follow-up).
