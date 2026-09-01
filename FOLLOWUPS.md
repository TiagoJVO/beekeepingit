# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/client-validation-parity` (#584 — revalidate queued edits before pushing)

- **After merge, fold the pre-push failure into #443's message mapping.**
  [#443](https://github.com/TiagoJVO/beekeepingit/issues/443) is building a rejection-code →
  localized-message mapping in `sync_needs_fix_screen.dart` /
  `sync_rejected_repository.dart`. This branch deliberately kept its surface to a single extra
  string: the needs-fix row shows `syncNeedsFixLocalProblem` when `errorCode` is
  `validation.failed.local`, and the generic message otherwise. A client-predicted rejection is
  the one case where the client **owns** the `(field, code)` pair, so #443 can render a real
  per-field message ("Name is required", EN/PT) for it at no extra cost — worth doing when that
  mapping lands, and it should replace the two-way branch rather than sit beside it.
- **The same evaluator wants a save-time call site.** `validateSyncOps`
  (`client/lib/core/validation/sync_op_validator.dart`) is a pure function of the wire op, so the
  form/repository write path can run it and tell the beekeeper _in the form_, with the record
  open, instead of at the next push. That is a genuine FR-OF-2 improvement and needs no new source
  of truth — but it touches every entity's form screen, so it is out of this PR's scope. Promote
  to an Issue under EPIC-06 (#7) if it isn't picked up with #585.

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
