# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

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

_Sweep note (post-#545/#551 deploy, 2026-08-23): all three remaining branch sections resolved._

- _The **#545 ownership transition ran on staging and is verified**: `v0.0.1-rc10` deployed with_
  _the one-release gate on (gitops#11 + #12), all 26 tables moved to their `<schema>_migrator`,_
  _history tables append-only, goose ledgers locked, and the gate then removed (gitops#13) —_
  _`beekeepingit`'s temporary migrator memberships confirmed revoked (role-graph count 0). Pruned._
- _**#551's AC1 — untestable in CI — is now confirmed live**: the rc10 rollout was exactly a first_
  _deploy of a cold image set, and no `*-migrate` Job hit `DeadlineExceeded`. Pruned._
- _#364's **first-link notification** item (its PR merged, #364 closed) → promoted to_
  _[#563](https://github.com/TiagoJVO/beekeepingit/issues/563); its remaining dependency was_
  _already tracked as [#510](https://github.com/TiagoJVO/beekeepingit/issues/510). Pruned._
- _[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still open — that_
  _entry stands. Prior sweep notes dropped with their entries, per this file's convention._
