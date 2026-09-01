# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `fix/sync-gate-reprobe-on-connectivity-return` (#240 — gate re-probes on reconnect)

- **Before merge: Helm-E2E is the only place the e2e change is actually exercised.** This
  branch removes the "Sync now" nudge `client/e2e/tests/slice.spec.ts` used after
  `context.setOffline(false)` (it existed precisely because the gate didn't re-probe on
  connectivity-return), so the reconnect-sync poll now depends on the new `online`-event
  interrupt firing under Playwright's offline emulation. Unit tests cover the gate itself; only
  the live run proves the browser event reaches it. If that run flakes, restore the nudge in
  `slice.spec.ts` (gate fix stays) rather than widening the poll timeout, and say so on the PR.

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

_Sweep note (#240, 2026-09-01): the `claude/orch-add-feature-6993c5` section is gone._

- _Its owning PR [#569](https://github.com/TiagoJVO/beekeepingit/pull/569) merged and #365 closed,_
  _so its "before merge: Helm-E2E must be green" bullet has served its purpose, and its second_
  _bullet said to prune itself once the PR landed. Both follow-ups it pointed at are already_
  _Issues ([#510](https://github.com/TiagoJVO/beekeepingit/issues/510),_
  _[#563](https://github.com/TiagoJVO/beekeepingit/issues/563)) — nothing was lost. Pruned._
- _[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still open — that_
  _entry stands. Prior sweep notes dropped with their entries, per this file's convention._
