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
- **Confirm (or rule out) the `journey.default_attributes` null case, and open an Issue if
  it's real.** `journeys_repository.dart` stores SQL NULL for an empty defaults bag, while
  `validateDefaultAttributes` (`services/journeys/api/types.go`) rejects a present JSON `null`
  — it skips only on `len(raw) == 0`. Whether that ever reaches the wire depends on whether
  PowerSync includes null columns in a `put`'s `opData`, which this branch did **not** verify.
  If it does, clearing a journey's defaults is already failing server-side today and #584 only
  makes it visible one step earlier; the fix belongs in `validateDefaultAttributes` (treat the
  `null` literal as absent, like every other optional field on that struct), after which the
  description's `jsonObject` check must skip an explicit null for that field. Written up in
  `contracts/validation/README.md`. Cheapest check: log one op's `opData` for a journey with no
  defaults, or add a `journeys` integration case.
- **The same evaluator wants a save-time call site.** `validateSyncOps`
  (`client/lib/core/validation/sync_op_validator.dart`) is a pure function of the wire op, so the
  form/repository write path can run it and tell the beekeeper _in the form_, with the record
  open, instead of at the next push. That is a genuine FR-OF-2 improvement and needs no new source
  of truth — but it touches every entity's form screen, so it is out of this PR's scope. Promote
  to an Issue under EPIC-06 (#7) if it isn't picked up with #585.

## `#296`/`#298` — DGAV registration + stock declarations (PR #593, merged)

- **`stock_declarations` runtime grants are still unexercised on a real environment.** Helm-E2E
  proved the table is CREATEd and that `charts/postgres`'s blanket
  `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES` (hook weight 3) applies without error —
  but **nothing in E2E writes a declaration**, so the grant is not exercised end-to-end. The
  reasoning holds (the table is new and NOT a `*_log`, and the publication is schema-scoped so
  PowerSync captures it automatically); confirm on the first environment where a beekeeper
  actually records one. Promote to an Issue if it isn't confirmed at the next deploy.

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

_Sweep note (2026-09-01, during #584): PR [#593](https://github.com/TiagoJVO/beekeepingit/pull/593)_
_merged, so its `claude/orch-add-feature-8816f4` branch section is stale by definition. Its_
_before-merge Helm-E2E gate was met at merge and its D-19 bullet said to "prune this bullet with the_
_section" — both pruned; the one genuinely open item (unexercised `stock_declarations` runtime_
_grants) is kept above under the merged issues it belongs to, since it is a live post-deploy_
_verification rather than a branch precondition. [#495](https://github.com/TiagoJVO/beekeepingit/issues/495)_
_re-checked and still open — that entry stands. Prior sweep notes dropped with their entries, per_
_this file's convention._
