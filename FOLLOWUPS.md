# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `fix/541-migrations-as-migrator-role` (#541 — migrations as a deploy-time admin process)

Before merge:

- **Verify the transition against a real cluster.** `REASSIGN OWNED BY <schema>_svc TO
beekeepingit` (`charts/postgres/templates/table-grants-job.yaml`) has only ever run in
  testcontainers. Staging is the one environment carrying pre-#541 state — tables owned by
  `<schema>_svc` from the old startup-migration path — so it is the only place the transition is
  genuinely exercised. Deploy there and confirm afterwards that every table in every service
  schema is owned by `beekeepingit`, and that `<schema>_svc` retains `INSERT`/`SELECT` only on
  `audit_log`/`sync_conflict_log`.
- **Staging currently carries a manual hand-fix.** On 2026-08-22 `organizations.audit_log`
  ownership was moved by hand to unblock the stuck `v0.0.1-rc8` rollout (migrations 5 and 6
  applied, ownership re-locked). That is _not_ what this branch does, and the by-hand state must
  be reconciled by an actual deploy of this branch — otherwise staging looks correct for the
  wrong reason and the transition stays untested.
- **`task lint` has never run on this branch.** `lefthook` is not on PATH in the authoring
  environment, so the commit-msg and format hooks were skipped on all commits here.

## `dependabot/npm_and_yarn/admin/typescript-7.0.2` (#495 — typescript 5.9.3 → 7.0.2)

- **Blocked on upstream `typescript-eslint`, not a routine dependency bump.** TypeScript
  7.0 is the new native/Go-ported compiler; `typescript-eslint` has no release (including
  prereleases through `8.65.1-alpha.8`) that supports it — its peer range caps at `<6.1.0`,
  and it refuses to run under TS 7 at all (not just a peer-range warning). `npm ci` itself
  fails in CI. Tracked upstream in
  [typescript-eslint#10940](https://github.com/typescript-eslint/typescript-eslint/issues/10940)
  (findings posted on the PR). `tsc --noEmit` alone is clean under TS 7 — this is purely a
  linting-toolchain gap, not a real type regression in the codebase. Re-check #495 once
  typescript-eslint ships TS 7.x support (or Dependabot supersedes it with a newer PR); prune
  this entry once #495 merges or is closed as superseded.

---

_Sweep note (#541): the `feat/google-federation-363` entry was stale — its PR_
_[#509](https://github.com/TiagoJVO/beekeepingit/pull/509) merged and_
_[#363](https://github.com/TiagoJVO/beekeepingit/issues/363) closed, so under this file's own rule_
_it could no longer ride along. Its work was never done (no environment has real Google OAuth_
_credentials), so it was promoted to_
_[#544](https://github.com/TiagoJVO/beekeepingit/issues/544) rather than pruned, and removed here._
_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still open — that entry_
_stands. The earlier #363 sweep had already handled #456/#508 in the same spirit._
