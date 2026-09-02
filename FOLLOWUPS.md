# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `#584`/`#585` — client↔server validation parity (PRs #591, #596)

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
  defaults, or add a `journeys` integration case. #596 now **pins the current behaviour** from
  both sides (corpus case `journey/patch/default-attributes-is-an-explicit-null`) — the two sides
  agree today, so if the server is relaxed here the description must be relaxed with it, and that
  case is what will say so.

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

_Sweep note (2026-09-02, closing out PR [#595](https://github.com/TiagoJVO/beekeepingit/pull/595)):_
_everything that branch was carrying is **resolved rather than deferred**, so its section is gone._

- _Its Helm-E2E precondition is met_
  _([run 33578751459](https://github.com/TiagoJVO/beekeepingit/actions/runs/33578751459), green on_
  _the renamed shape). Its in-place-migration precondition still holds — `v0.0.1-rc13`_
  _(2026-09-01 10:20Z) is still the newest release and predates those migrations, so no deployed_
  _database holds the old column name. And its `stock_declarations` runtime-grants bullet is now_
  _exercised end to end: the rewritten `stock-declarations.spec.ts` records a declaration and_
  _asserts a **fresh** client downloads it, which only works if the server INSERTed the row._
- _`If-Match` on the organization-details save was opened as_
  _[#601](https://github.com/TiagoJVO/beekeepingit/issues/601) and then \**implemented on the same_
  _branch\**, so it closes with that PR rather than outliving it._
- _The `#584`/`#585` section's `_fieldLabel` bullet is **implemented, not promoted**: it asked for_
  _labels for `declared_on`, `total_hive_count` and `registration_number` — fields #595 introduced —_
  _and was marked "needs an owner" only because its original issue (#443) had closed._

_Its sibling `journey.default_attributes` bullet **stays here deliberately**. It was verified true_
_(PowerSync's `powersync_diff` omits nulls from a `put` but emits an explicit `null` from a patch_
_that clears a column, so clearing a journey's defaults has never been able to sync) and is fixed —_
_but in its **own PR**, since it is journeys and the shared validation description rather than_
_apiaries. Prune this bullet when that PR merges._

_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked: still open — blocked on_
_upstream `typescript-eslint` supporting TypeScript 7, so it is genuinely not ours to close._
_Prior sweep notes dropped with their entries, per this file's convention._

_Sweep note (2026-09-02, during #600 / PR [#602](https://github.com/TiagoJVO/beekeepingit/pull/602)):_
_no entries added or pruned — [#595](https://github.com/TiagoJVO/beekeepingit/pull/595) landed the_
_labels first, so #600's remaining half is the test guard that keeps them from silently going_
_missing again, which owes this file nothing. Sections re-checked and left as #595 wrote them:_
_the `journey.default_attributes` bullet is still pending its own journeys PR, and_
_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) is still open upstream._
