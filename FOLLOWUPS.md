# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `fix/545-per-schema-migrator-roles` (#545 — per-schema `<schema>_migrator` roles)

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
    `<schema>_svc` becomes unreachable. As of 2026-08-22 staging still had **16 tables owned by
    `<schema>_svc`** (organizations 4, apiaries 3, journeys 3, todos 2, activities 2, identity 2)
    plus a hand-fixed `organizations.audit_log` — all of which #541's own `REASSIGN OWNED BY` step
    adopts on its first deploy. The adopt Job checks for this and fails the release naming the
    offending relations, so the failure mode is loud, but it costs a staging round-trip.
  - **Leaving the gate on is not harmless.** While it is on, `beekeepingit` is a member of all
    seven migrator roles — the exact cross-schema bridge this change removes. Isolation is a
    steady-state property (ADR-0024 §4).
- **Confirm afterwards** that every relation in every schema is owned by its own
  `<schema>_migrator`, that no `pg_default_acl` row is scoped to `beekeepingit`, and that
  `<schema>_svc` still holds `INSERT`/`SELECT` only on `audit_log`/`sync_conflict_log` and nothing
  on `goose_db_version`. Queries are in the runbook.

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

_Sweep note (#545): the whole `fix/541-migrations-as-migrator-role` section was stale — #541 closed_
_and PR [#546](https://github.com/TiagoJVO/beekeepingit/pull/546) merged, so under this file's own_
_rule it could not ride along. Resolved rather than re-described:_

- _the staging **ownership-transition validation** is superseded by #545's own transition (the_
  _`REASSIGN OWNED BY <schema>_svc` step it referred to no longer exists), and is carried forward_
  _above, including the pre-#541 state it recorded and the hand-fixed `organizations.audit_log`;_
- _the **hardcoded history-table name list** was already promoted to_
  _[#553](https://github.com/TiagoJVO/beekeepingit/issues/553) — #545 narrowed half of it_
  _(`ALTER DEFAULT PRIVILEGES` no longer makes a new history table mutable at creation) and_
  _deliberately left the rest there;_
- _the **baseline re-cut constraint** is recorded in_
  _[ADR-0023](docs/adr/0023-migrations-as-a-deploy-time-admin-process.md)'s Consequences, which is_
  _where a standing operational rule belongs — pruned here rather than kept in two places._

_The `claude/orch-change-feature-d959be` (#539) section was also stale — #539 closed and its_
_manual round-trip was promoted to [#554](https://github.com/TiagoJVO/beekeepingit/issues/554),_
_so it is pruned. [#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still_
_open — that entry stands._
