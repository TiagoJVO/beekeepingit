# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/account-linking-364` (#364 — federated account linking)

- **Notify the account owner when a sign-in method is first linked.** The one missing detection
  control for the residual risk #364 accepts and documents (`docs/architecture/auth.md` §8.14): an
  upstream address that changes hands — a Workspace mailbox reassigned to a new hire — can link
  into an account that was never deactivated, and nothing today tells the owner it happened.
  Authentik already raises a `SOURCE_LINKED` Event when `PostSourceStage` persists a new
  connection, so the work is binding a **notification rule + transport** to that event in the
  blueprint; the SMTP path #361 built is already there. **Not a merge blocker:** federation is
  inert until an environment has Google credentials, and none holds real user data yet (D-26). It
  **is** a prerequisite for enabling federation on one that does — i.e. alongside
  [#510](https://github.com/TiagoJVO/beekeepingit/issues/510), before #365's environment.
  _Promote to a GitHub Issue and prune this entry once referenced._

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

_Sweep note (#364): the `feat/google-federation-363` entry was stale — #363 closed with PR #509,_
_so under this file's own rule it could no longer ride along. Its work (creating the Google_
_credentials Secret and running the manual verification checklist against a real Google client) is_
_genuinely outstanding and now covers #364's first-link case too, so it is promoted to_
_[#510](https://github.com/TiagoJVO/beekeepingit/issues/510), a sub-issue of EPIC-14_
_[#15](https://github.com/TiagoJVO/beekeepingit/issues/15) — the same treatment #508 got in the_
_#363 sweep — and pruned here. #510 is also `feat/account-linking-364`'s one unverifiable-in-CI_
_dependency; beyond CI and the entry below, that branch owes nothing before merge._

_Earlier sweep note (#363): the `feat/authentik-admin-oidc-client` (#456) entry was stale — #456_
_closed long ago. Its remaining work (tightening the admin client's `http://localhost:.*` redirect_
_entry for staging/prod) is now_
_[#508](https://github.com/TiagoJVO/beekeepingit/issues/508), a sub-issue of EPIC-14_
_[#15](https://github.com/TiagoJVO/beekeepingit/issues/15), and was pruned then. #362's own sweep_
_had already pruned the #449 and #290 entries in the same spirit._
