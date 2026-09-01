# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `fix/sync-gate-reprobe-on-connectivity-return` (#240 — gate re-probes on reconnect)

- **Keep Helm-E2E green on the final pre-merge run — it is the only place the e2e change is
  actually exercised.** This branch removes the "Sync now" nudge `client/e2e/tests/slice.spec.ts`
  used after `context.setOffline(false)` (it existed precisely because the gate didn't re-probe
  on connectivity-return), so the reconnect-sync poll now depends on the new `online`-event
  interrupt firing under Playwright's offline emulation. Unit tests cover the gate itself; only
  the live run proves the browser event reaches it. **Verified: green twice** (runs
  `33513344172` and `33519801347`) — the walking-skeleton case (login → create → offline edit →
  sync) passed in ~1.1–1.2 min each, nudge-free. If a later run flakes, restore the nudge in
  `slice.spec.ts` (the gate fix stays) rather than widening the poll timeout, and say so on the
  PR. Prune this entry when #240's PR merges.

## `claude/orch-add-feature-8816f4` (#296, #298 — EPIC-02's two remaining regulatory stories)

- ~~**Before merge: a green Helm-E2E.**~~ **Met** — [run
  33522048949](https://github.com/TiagoJVO/beekeepingit/actions/runs/33522048949) passed
  (17m). That gate is the first place all three migrations (`apiaries` `00009`/`00010`,
  `organizations` `00007`) and the new PowerSync sync-rules entries actually execute together;
  local Go/Dart tests cover the service and client halves in isolation but never the
  replication path, and a sync-rules entry that fails to parse is historically **silent** (the
  #23-deploy shape: replication fatals, nothing reports the file invalid). It is green, so this
  item is closed rather than pending — kept only until the PR merges, as the reviewer's
  evidence.
- **Still open: `stock_declarations` runtime grants on a real environment.** The Helm-E2E run
  above proves the table is CREATEd and that `charts/postgres`'s blanket
  `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES` (hook weight 3) applies without error —
  but **nothing in E2E writes a declaration**, so the grant is not exercised end-to-end. The
  reasoning holds (the table is new and NOT a `*_log`, and the publication is schema-scoped so
  PowerSync captures it automatically); confirm on the first environment where a beekeeper
  actually records one.
- **Deferred, not forgotten: two of D-19's five flagged data points remain untriaged** — the
  structured disease/condition field on Treatment activities, and the honey lot/batch
  identifier. (The retention-policy note was triaged separately by #295 while this branch was
  in flight; #296/#298 triage the registration number and the stock-declaration record.) The
  two that remain belong to their own owning epics (activities, import/export), are recorded in
  D-19 and in `docs/research/regulatory-pt-eu-beekeeping.md` §6, and need no entry of their own
  here once this PR merges — prune this bullet with the section.

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

_Sweep note (2026-09-01, during #295): [#365](https://github.com/TiagoJVO/beekeepingit/issues/365)_
_closed and its branch merged, so the `claude/orch-add-feature-6993c5` section is resolved by_
_definition — its Helm-E2E merge precondition was met at merge, and its two after-merge items were_
_already Issues ([#510](https://github.com/TiagoJVO/beekeepingit/issues/510),_
_[#563](https://github.com/TiagoJVO/beekeepingit/issues/563)) that the entry itself said to prune on_
_landing. Pruned. [#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still_
_open — that entry stands. Prior sweep notes dropped with their entries, per this file's convention._
