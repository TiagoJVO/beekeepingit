# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `fix/dgav-declaration-date-and-note` (PR #595 — FR-AP-9/FR-AP-10 follow-ups on top of #593)

> This branch started as the declaration date + note fix and now also carries the
> **authority-neutral rework** of the same feature (D-19's narrowing note): `registration_number`
> everywhere, the Portugal-specific advisory logic deleted, and `/dgav` split into an
> organization-details screen and a stock-declarations screen.

- **Before merge: the in-place migration edits must land before the next release.** `#593`
  merged at 15:26Z today; the newest release is `v0.0.1-rc13` (10:20Z, **before** it), so its
  three migrations (`organizations` `00007`, `apiaries` `00009`/`00010`) have **never run on a
  real environment**. That is the only reason the rename can edit them **in place** rather than
  adding a fourth `ALTER … RENAME COLUMN` migration: no deployed database holds a
  `dgav_registration_number` column to rename. Renaming the two migration **files** is separately
  safe (goose keys `goose_db_version` by version id, not filename). If this branch is still open
  when a release promotes `main`, that assumption dies and the rename must become its own
  forward migration — re-check `gh release list` before merging.
- **Before merge: a green Helm-E2E.** #593's run
  ([33522048949](https://github.com/TiagoJVO/beekeepingit/actions/runs/33522048949)) proved the
  original shape, not this one: the rename touches the same three migrations **and** the
  PowerSync sync-rules column list, which is the pairing that fails **silently** (a sync-rules
  entry that no longer matches a renamed column doesn't error — the column just stays NULL on
  fresh devices, and every local-only test still passes). Helm-E2E is the only gate that runs
  the migrations and the replication path together.
- **Deferred: `If-Match`/ETag on `PATCH /v1/organizations/{id}`.** The organization-details
  save now sends only the fields that actually changed (diffed against the organization the
  screen was seeded from), which removes the lost-update and audit-misattribution window for
  every field the user did not touch. It does **not** close the window for a field two admins
  edit concurrently — last write still wins, silently. The stronger fix is optimistic
  concurrency: the server already treats an absent `If-Match` as "proceed"
  (`services/organizations/api/organizations.go`, `ifMatchOK`), so the client just has to send
  one. Deferred because `ApiClient.patchJson` takes no per-request headers, so threading an
  ETag from `GET /organizations/me` through to the PATCH is an `ApiClient`-wide change (every
  caller's signature) rather than a repository-local one — out of scope for this branch.
  **Promote to an Issue if this branch merges before it is done.**
- **Still open: `stock_declarations` runtime grants on a real environment.** #593's Helm-E2E run
  proved the table is CREATEd and that `charts/postgres`'s blanket
  `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES` (hook weight 3) applies without error —
  but **nothing in E2E writes a declaration**, so the grant is not exercised end-to-end. The
  reasoning holds (the table is new and NOT a `*_log`, and the publication is schema-scoped so
  PowerSync captures it automatically); confirm on the first environment where a beekeeper
  actually records one. If this branch merges without that confirmation, **promote this bullet
  to an Issue** rather than letting it ride here — it outlives the PR that found it.

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

_Sweep note (2026-09-01, during the FR-AP-9/FR-AP-10 authority-neutral rework):_
_[#593](https://github.com/TiagoJVO/beekeepingit/pull/593) **merged** and #296/#298 both closed, so_
_the `claude/orch-add-feature-8816f4` section was stale by definition and is pruned — its Helm-E2E_
_precondition was met at merge (git history keeps that record), and its "two of D-19's five data_
_points remain untriaged" bullet said to prune itself with the section; D-19 and_
_`docs/research/regulatory-pt-eu-beekeeping.md` §6 already carry that fact. Its one genuinely_
_pending item — the `stock_declarations` runtime grants — moved to the in-flight branch that now_
_owns this feature, with an explicit "promote to an Issue if it outlives the PR" trigger._
_[#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked: still open, entry stands._
_Prior sweep notes dropped with their entries, per this file's convention._
