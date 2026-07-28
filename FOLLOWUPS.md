# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/google-federation-363` (#363 — Google federation + "Continue with Google")

After merge (NOT merge blockers — nothing can exercise these until an environment has real Google
credentials, and none exists yet):

- **Run the manual verification checklist** in `infra/README.md`
  ("Enabling 'Continue with Google' on an environment") once against an environment with a real
  Google OAuth client. It covers the only things no automated test can reach: a completed
  sign-in through Google, the invitation-only refusal for an unlinked Google account, that a
  linked account resolves to the same `sub`, and that sign-out still revokes the SSO session
  after a _federated_ login. Record the result on #363. Until then, the Google-specific half of
  this feature is config-verified and doc-verified but not execution-verified — stated plainly in
  `docs/architecture/auth.md` §8.13.
- **Create the `beekeepingit-authentik-google-credentials` Secret** (staging first) per the same
  README section; the feature is inert until it exists, by design.

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
