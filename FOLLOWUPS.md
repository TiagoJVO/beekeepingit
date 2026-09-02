# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

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

_Sweep note (2026-09-02, on `fix/journey-default-attributes-explicit-null`):_
_The whole `#584`/`#585` section is gone. Its `journey.default_attributes` bullet was the open_
_question "does PowerSync put null columns on the wire?" — measured against the real_
_`powersync-sqlite-core` extension (a `patch` clearing a column DOES emit an explicit JSON `null`;_
_a `put` drops null columns), so it was a live bug, fixed by that branch rather than promoted; the_
_evidence lives in `contracts/validation/README.md`. Its `_fieldLabel` bullet belongs to_
_[#600](https://github.com/TiagoJVO/beekeepingit/issues/600), landed by PR_
_[#602](https://github.com/TiagoJVO/beekeepingit/pull/602), which prunes it too — whichever of the_
_two merges second, the section ends up gone either way._
_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still open — that entry stands._
_[#597](https://github.com/TiagoJVO/beekeepingit/issues/597) is open and tracked in Issues, not here._
_Prior sweep notes dropped with their entries, per this file's convention._
