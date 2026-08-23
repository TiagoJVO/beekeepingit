# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/545-per-schema-migrator-roles` (#545 — per-schema `<schema>_migrator` roles)

Before merge:

- **Nothing.** The chart renders and lints in all three environments with the transition gate in
  both positions, and the two new testcontainers suites pass alongside the existing ones.

After this merges and reaches staging via a release (D-27: merge → release → tag-bump PR → Flux
reconciles — staging is never deployed from a branch):

- **Run the #545 ownership transition on staging, once, and then turn the gate back off.** Runbook
  and verification queries: `infra/README.md` → "Transitioning an existing cluster (#545)". Two
  things make this a real step rather than a formality:
  - **#541's release must have deployed to staging first.** The transition swaps `beekeepingit`'s
    `<schema>_svc` memberships for the migrator ones, so any relation still owned by
    `<schema>_svc` becomes unreachable. This precondition is now **met**: per the #551 sweep note
    below, `v0.0.1-rc9` deployed 2026-08-22 and all 26 previously `<schema>_svc`-owned tables
    (including the hand-fixed `organizations.audit_log`) are owned by `beekeepingit`, verified
    against the live cluster. The adopt Job's preflight guard still checks and fails the release
    naming any offending relations, so a regression stays loud rather than a bare
    `must be owner of ...`.
  - **Leaving the gate on is not harmless.** While it is on, `beekeepingit` is a member of all
    seven migrator roles — the exact cross-schema bridge this change removes. Isolation is a
    steady-state property (ADR-0024 §4).
- **Confirm afterwards** that every relation in every schema is owned by its own
  `<schema>_migrator`, that no `pg_default_acl` row is scoped to `beekeepingit`, and that
  `<schema>_svc` still holds `INSERT`/`SELECT` only on `audit_log`/`sync_conflict_log` and nothing
  on `goose_db_version`. Queries are in the runbook.

## `fix/551-migrate-job-pull-deadline` (#551 — migration bound moves off the pod's lifetime)

- **AC1 can only be confirmed by a real release.** "A first deploy of a not-yet-pulled version does
  not fail the release on image-pull time" is unreproducible in `helm-e2e`, which pre-imports images
  into k3d so pull time is always zero. Confirm on the next staging release that no `*-migrate` Job
  reports `DeadlineExceeded` while the node pulls a cold image set, then prune this entry.

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

_Sweep note (#551): both remaining branch sections were stale — [#546](https://github.com/TiagoJVO/beekeepingit/pull/546)_
_merged (closing [#541](https://github.com/TiagoJVO/beekeepingit/issues/541)) and_
_[#539](https://github.com/TiagoJVO/beekeepingit/issues/539) closed, so under this file's own rule_
_neither could ride along. Resolved rather than left to drift:_

- _#541's **staging ownership transition** and **manual hand-fix reconciliation** are **done** —_
  _`v0.0.1-rc9` deployed 2026-08-22 and all 26 tables are now owned by `beekeepingit`, with_
  _`<schema>_svc` holding `INSERT`/`SELECT` only on `audit_log`/`sync_conflict_log`. Verified against_
  _the live cluster; pruned, since git history and the PR already record it._
- _#541's **baseline re-cut constraint** is now durable documentation, not pending work — it lives_
  _in [ADR-0023](docs/adr/0023-migrations-as-a-deploy-time-admin-process.md) §5. Pruned._
- _#541's **hardcoded history-table list** still has real work → promoted to_
  _[#553](https://github.com/TiagoJVO/beekeepingit/issues/553)._
- _#539's **staging round-trip** and **control-plane tier check** were never executed → promoted to_
  _[#554](https://github.com/TiagoJVO/beekeepingit/issues/554). Operator work by design: it needs real_
  _Scaleway credentials, which `infra/README.md` says an agent must not handle._

_Earlier sweep notes (#363, #539, #541) are dropped along with their entries — the Issues they point_
_at carry the record now. One lesson worth keeping: a stale entry may already have been promoted on_
_an unmerged branch, so check open Issues before filing a new one ([#544](https://github.com/TiagoJVO/beekeepingit/issues/544)_
_was filed as a duplicate of [#510](https://github.com/TiagoJVO/beekeepingit/issues/510) exactly that way)._

_Sweep note (#545, at the merge with main): the #545 branch had independently swept the same stale_
_sections (#541/#546, #539) from its own base; the two sweeps concurred on every disposition, so the_
_#551 note above stands as the single record rather than being repeated. What the merge reconciled:_
_the #545 section's "deploy #541 first" precondition, written 2026-08-22 against a staging cluster_
_that still had 16 `<schema>_svc`-owned tables, is **satisfied** by the `v0.0.1-rc9` deploy the #551_
_sweep verified — the entry above now says so instead of describing the pre-rc9 state. #545 also_
_narrowed half of [#553](https://github.com/TiagoJVO/beekeepingit/issues/553) — the default_
_privileges no longer make a new history table mutable at creation — and deliberately left the_
_rest there. [#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still open —_
_that entry stands._
