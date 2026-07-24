# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

_(empty — nothing pending; PR #418's before-merge item (create the `cluster-ops.yml`
secrets/variables) is done — the `staging-gate` set is in place. `production-gate` secrets are
not owed here: prod is deferred until DR (`Q-DR`) + #90 land (D-26), and the fill-in steps live in
`infra/README.md#secrets--remote-cluster-operations`. The `DEPLOY_NOTIFY_TOKEN` manual step remains
tracked in [#413](https://github.com/TiagoJVO/beekeepingit/issues/413), still open.)_
