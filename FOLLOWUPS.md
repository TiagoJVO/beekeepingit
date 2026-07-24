# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Branch: cluster secrets/env loading + `cluster-ops.yml` (D-26/D-27)

- [ ] **After merge — create the GitHub secrets/variables `cluster-ops.yml` needs** (manual,
      GitHub UI/`gh` — an agent must not handle the values; see
      `infra/README.md#secrets--remote-cluster-operations` for the full inventory + commands):
      `SCW_ACCESS_KEY`/`SCW_SECRET_KEY`/`SCW_DEFAULT_PROJECT_ID`/`SCW_DEFAULT_ORGANIZATION_ID`,
      `CF_API_TOKEN`/`CF_ZONE_ID` (optional), `AUTHENTIK_EMAIL_USERNAME`/`_PASSWORD` (optional) —
      scoped to the `staging-gate`/`production-gate` environments — plus the non-secret
      `APP_HOST`/`AUTH_HOST` environment variables. Until they exist, a `cluster-ops` dispatch
      fails at the scripts' credentials pre-flight (by design, with a clear message). A first
      real staging `up` run from the Actions tab is the end-to-end verification.

_(previous sweep: the `DEPLOY_NOTIFY_TOKEN` entry's owning PRs (#375 here, beekeepingit-gitops#5)
merged; its remaining manual step was promoted to
[#413](https://github.com/TiagoJVO/beekeepingit/issues/413), which is still open.)_
