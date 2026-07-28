# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/google-federation-363` (#363 — Google federation + "Continue with Google")

Before merge:

- **The live e2e and the in-cluster probe have never run.** `client/e2e/tests/federation.spec.ts`
  and `infra/ci/authentik-federation-probe.py` were written against source-verified Authentik
  2026.5.4 behavior but authored without a cluster; their first real execution is this PR's
  `helm-e2e` job. Read that job's output before merging — a red probe/spec here is a real finding,
  not flake. Everything else in the change (Helm renders for all three overlays, the blueprint
  posture guard including its negative cases, Flutter analyze + the full `flutter test` suite,
  prettier/markdownlint) was verified locally.

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

## `feat/admin-app-deploy-and-cors` (#449 — admin host + cross-origin CORS)

- **Per-environment admin nginx CSP** — `admin/nginx.conf` ships its
  `Content-Security-Policy-Report-Only` with the **dev** `connect-src` hosts
  (`https://app.beekeepingit.local:8443` / `auth…`) hardcoded. `release-deploy.yml`'s
  `publish-admin` now bakes the **staging/prod** `VITE_*` API/issuer hosts into the image, so a
  non-dev admin build's real API host is **not** in its CSP — harmless today only because the
  policy is **Report-Only** (it reports, does not block). Env-templating the admin (and client)
  nginx CSP is tracked in [#462](https://github.com/TiagoJVO/beekeepingit/issues/462); flipping
  the admin CSP to **enforcing** must wait for that per-environment templating, or a staging/prod
  admin build would block its own API calls. **Not a merge blocker** (Report-Only). Prune once
  #462 lands the templating.

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

_Sweep note (#363): three entries were stale — their owning issue/PR had already closed._
_`#456`'s admin-redirect hardening was promoted to_
_[#508](https://github.com/TiagoJVO/beekeepingit/issues/508) (sub-issue of EPIC-14 #15) and pruned_
_here; `#290`'s re-invite reactivation was already tracked in_
_[#459](https://github.com/TiagoJVO/beekeepingit/issues/459) and pruned; `#418`'s `cluster-ops.yml`_
_secrets note was long since done. `production-gate` secrets are not owed: prod is deferred until_
_DR (`Q-DR`) + #90 land (D-26), and the fill-in steps live in_
_`infra/README.md#secrets--remote-cluster-operations`. `DEPLOY_NOTIFY_TOKEN` remains tracked in_
_[#413](https://github.com/TiagoJVO/beekeepingit/issues/413), still open._
