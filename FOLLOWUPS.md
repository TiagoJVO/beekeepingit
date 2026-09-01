# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `claude/orch-add-feature-8816f4` (#296, #298 — EPIC-02's two remaining regulatory stories)

- **Before merge: the Helm-E2E gate is the first place the new sync rules and both new
  migrations actually run together.** The apiaries service gains two migrations (`00009`
  per-apiary `dgav_registration_number`, `00010` `stock_declarations`) and organizations gains
  one (`00007`), and the PowerSync sync-rules bucket gains a column plus a whole table entry
  (`infra/helm/beekeepingit/charts/powersync/values.yaml`). Local Go/Dart tests cover the
  service and client halves in isolation; what they cannot exercise is the replication path —
  a sync-rules entry that fails to parse is historically **silent** (the #23-deploy shape:
  replication fatals, nothing reports the file invalid). Treat a green Helm-E2E as a merge
  precondition, not a formality.
- **Watch the first deploy's `stock_declarations` table grants.** The table is new and NOT a
  `*_log`, so `charts/postgres`'s blanket `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES`
  at hook weight 3 should cover it with no infra change (and the publication is schema-scoped,
  so PowerSync captures it automatically). That is reasoned from the chart, not observed —
  confirm on the first environment that actually runs migration `00010`.
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
