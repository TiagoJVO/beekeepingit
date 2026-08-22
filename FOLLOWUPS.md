# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `fix/541-migrations-as-migrator-role` (#541 — migrations as a deploy-time admin process)

After this merges and reaches staging via a release (D-27: merge → release → tag-bump PR → Flux
reconciles — staging is never deployed from a branch):

- **Validate the ownership transition on staging.** `REASSIGN OWNED BY <schema>_svc TO
beekeepingit` (`charts/postgres/templates/table-grants-job.yaml`) has only ever run in
  containers. Staging is the one environment carrying pre-#541 state, so it is the only place the
  transition is genuinely exercised. As of 2026-08-22 it has **16 tables still owned by
  `<schema>_svc`** (organizations 4, apiaries 3, journeys 3, todos 2, activities 2, identity 2) and
  10 already owned by `beekeepingit`. Afterwards, confirm all 26 are owned by `beekeepingit` and
  that `<schema>_svc` holds `INSERT`/`SELECT` only on `audit_log`/`sync_conflict_log`. Already
  verified as safe to run: no `<schema>_svc` owns anything outside its own schema, which is the
  one thing `REASSIGN OWNED`'s database-wide scope could have caught out.
- **The same release reconciles a manual hand-fix.** On 2026-08-22 `organizations.audit_log`
  ownership was moved by hand to unblock the stuck `v0.0.1-rc8` rollout (migrations 5 and 6
  applied, ownership re-locked). Until this ships, staging looks correct for the wrong reason.
- **The history-table list in `table-grants-job.yaml` is hardcoded** to `audit_log` and
  `sync_conflict_log`. `ALTER DEFAULT PRIVILEGES` makes UPDATE/DELETE the default for anything a
  future migration creates in the schema, and only those two literal names are revoked back. A
  future history-style table under a different name would silently keep UPDATE/DELETE for the
  runtime role. Decide before more history tables land: adopt a naming convention the job can
  match, or an explicit allowlist that fails the release on an unrecognised table. From the
  security review of this branch; promote to an Issue if it outlives this PR.
- **Re-cutting a migration baseline requires every live environment at or above its version.**
  This branch squashed each service's migrations into a single `0000N_baseline.sql` numbered at the
  then-current max (verified equal to staging's ledger for all six services). Squashing below a
  deployed cluster's version would make goose apply the baseline over tables that already exist.
  The local k3d dev cluster was behind (organizations at 4) and must be recreated with
  `infra/cluster/dev-up.sh` rather than upgraded in place.

## `claude/orch-change-feature-d959be` (#539 — pause/resume Scaleway environments without losing data)

Not a merge blocker for the code/docs in this branch, but the issue's own "Verification" AC
("a staging round-trip is exercised end to end") cannot be executed by an agent — it needs a
human operator with real Scaleway credentials, per `infra/README.md`'s own "an agent must not
handle these values" convention:

- **Run the staging round-trip**: seed a recognisable row, `scaleway-scale-down.sh`,
  `scaleway-scale-up.sh`, confirm the row survives and the app works. Record the result on #539.
  Until then, the pause/resume design is research-verified (ADR-0022) and shellcheck/actionlint-clean
  but not execution-verified against real infra.
- **Confirm the staging cluster's control-plane tier** is Mutualized (free), not a paid Dedicated
  tier (`scw k8s cluster get <id> region=fr-par` → check `.Type`) — flagged as unconfirmed in
  ADR-0022/`infra/README.md`.

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

_Sweep note (#363): the `feat/authentik-admin-oidc-client` (#456) entry was stale — #456 closed_
_long ago, so under this file's own rule it could no longer ride along. Its remaining work_
_(tightening the admin client's `http://localhost:.*` redirect entry for staging/prod) is now_
_[#508](https://github.com/TiagoJVO/beekeepingit/issues/508), a sub-issue of EPIC-14_
_[#15](https://github.com/TiagoJVO/beekeepingit/issues/15), and is pruned here. #362's own sweep_
_had already pruned the #449 and #290 entries in the same spirit._

_Sweep note (#539): the `feat/google-federation-363` (#363) entry was stale — #363 closed and its_
_manual-verification follow-up was already promoted to_
_[#510](https://github.com/TiagoJVO/beekeepingit/issues/510), so it's pruned here rather than_
_riding along a second time._

_Sweep note (#541): this branch swept the same stale `feat/google-federation-363` entry_
_independently, from a base that predated #539's sweep, and promoted it to a **duplicate**_
_issue — [#544](https://github.com/TiagoJVO/beekeepingit/issues/544), since closed in favour of_
_[#510](https://github.com/TiagoJVO/beekeepingit/issues/510). Worth remembering: a stale entry may_
_already have been promoted on an unmerged branch, so check open Issues for the work before_
_filing a new one. [#495](https://github.com/TiagoJVO/beekeepingit/issues/495) re-checked and still_
_open — that entry stands._
