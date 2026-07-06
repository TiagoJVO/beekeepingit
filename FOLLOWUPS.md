# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before/after merging `renovate.json` (#155)

- **Install the [Renovate GitHub App](https://github.com/apps/renovate)** on this repo
  (Settings → GitHub Apps) — a one-time manual step in the GitHub UI that can't be scripted
  from here. `renovate.json` takes effect as soon as it's installed (no onboarding PR). Until
  then the config sits inert. Prune this entry once installed.
