# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merge: `github-deployments-config` branch (ADR-0018 addendum)

- **`DEPLOY_NOTIFY_TOKEN` secret must be created before `notify-deploy.yml` will work** —
  a fine-grained PAT scoped to `TiagoJVO/beekeepingit` only, **Deployments: Read and write**
  permission, set as a repo secret on `beekeepingit-gitops`
  (`gh secret set DEPLOY_NOTIFY_TOKEN --repo TiagoJVO/beekeepingit-gitops`). Can't be created by
  an agent (requires the GitHub UI). Until it's set, `notify-deploy.yml` runs on every tag-bump
  merge but fails at the `gh api` step — the tag-bump/Flux-reconcile path itself is unaffected.
  Where: `beekeepingit-gitops`'s `notify-deploy` PR (branch `add-notify-deploy-workflow`),
  ADR-0018 addendum.
