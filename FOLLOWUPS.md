# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/authentik-admin-oidc-client` (#456 — admin OIDC client in the blueprint)

Post-merge hardening (NOT merge blockers — the blueprint provisioning is complete and the
`beekeepingit-admin` login/aud/iss is pinned by the helm-e2e admin-login gate):

- **Harden the admin OIDC redirect set for staging/prod** — the gateway `adminHost` route and the
  staging/prod `global.adminOrigin` overrides are now in place (#449), so the admin app IS
  gateway-served per environment. What remains is blueprint-side: the `http://localhost:.*` redirect
  entry is dev-convenience and belongs to the EPIC-14 hardened-blueprint variant, not prod — tighten
  the admin client's redirect_uris to the real per-environment admin origin there. Owner: EPIC-14.

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
