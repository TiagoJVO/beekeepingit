# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## `claude/epic-rules-backlog-review-c91e55`

- **Open a PR for the `requirements/` decision updates** — commit `34c3f20` records
  `D-21`..`D-25` (journey attribution, AI provider/GDPR posture, todo assignment,
  notifications, import semantics) and retires the five `Q-*` they resolve. Committed
  locally, not yet pushed/PR'd. The GitHub-issue side of the same backlog reorg (labels,
  milestones incl. new `M12 · Import`, ~12 net-new stories, dependency graph) is already
  live — that part has no branch/PR, it's direct issue-tracker state.
