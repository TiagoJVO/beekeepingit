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

_Sweep note (2026-09-02, on `fix/journey-default-attributes-explicit-null`):_
_The `#584`/`#585` section is gone. Its `journey.default_attributes` bullet was the open question_
_"does PowerSync put null columns on the wire?" — measured against the real `powersync-sqlite-core`_
_extension (a `patch` clearing a column DOES emit an explicit JSON `null`; a `put` drops null_
_columns), so it was a live bug, fixed by this branch rather than promoted. The evidence lives in_
_`contracts/validation/README.md`._

_Its `_fieldLabel` sibling was already pruned by_
_[#595](https://github.com/TiagoJVO/beekeepingit/pull/595), which implemented labels for the three_
_fields it introduced. The wider localization of the needs-fix screen is still open as_
_[#600](https://github.com/TiagoJVO/beekeepingit/issues/600) (PR_
_[#602](https://github.com/TiagoJVO/beekeepingit/pull/602)) — tracked in Issues, not here._

_The `#296`/`#298` section went with #595, whose e2e now records a declaration end to end._

_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still open — that entry stands._
_[#597](https://github.com/TiagoJVO/beekeepingit/issues/597) is open and tracked in Issues, not here._
_Prior sweep notes dropped with their entries, per this file's convention._

_Sweep note (2026-09-02, during #600 / PR [#602](https://github.com/TiagoJVO/beekeepingit/pull/602)):_
_no entries added or pruned — [#595](https://github.com/TiagoJVO/beekeepingit/pull/595) landed the_
_labels first, so #600's remaining half is the test guard that keeps them from silently going_
_missing again, which owes this file nothing. Sections re-checked and left as #595 wrote them:_
_the `journey.default_attributes` bullet is still pending its own journeys PR, and_
_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) is still open upstream._
