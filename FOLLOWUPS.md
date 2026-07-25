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

- **Assert the admin token's claim SHAPE in e2e, not just "login succeeds"** — the `iss`/`aud`
  override rides version-sensitive Authentik internals (oidc-integration.md §8 watch-list). The
  helm-e2e / admin login e2e should assert the minted token's `iss` == the beekeepingit issuer and
  `aud` == `[beekeepingit-admin, beekeepingit-pwa]`, so an Authentik bump that adds a reserved-claim
  guard or starts enforcing `azp`-with-multi-`aud` fails loudly in CI instead of as a silent prod 401. Owner: WS-C/e2e. (security review, #456.)
- **Guard which providers may carry `scope-admin-audience`** — any provider that attaches the
  override mapping inherits acceptance by the domain services. Consider a lightweight blueprint/CI
  assertion that ONLY `provider-beekeepingit-admin` carries it, so a future PR can't silently widen
  the set. (security review, #456.)
- **Harden the admin OIDC redirect set for staging/prod** — the gateway `adminHost` route and the
  staging/prod `global.adminOrigin` overrides are now in place (#449), so the admin app IS
  gateway-served per environment. What remains is blueprint-side: the `http://localhost:.*` redirect
  entry is dev-convenience and belongs to the EPIC-14 hardened-blueprint variant, not prod — tighten
  the admin client's redirect_uris to the real per-environment admin origin there. Owner: EPIC-14.

## `feat/admin-app-deploy-and-cors` (#449 — admin host + cross-origin CORS)

- **Per-environment admin nginx CSP** — `admin/nginx.conf` ships its
  `Content-Security-Policy-Report-Only` with the **dev** `connect-src` hosts
  (`https://app.beekeepingit.local:8443` / `auth…`) hardcoded. `release-deploy.yml`'s
  `publish-admin` now bakes the **staging/prod** `VITE_*` API/issuer hosts into the image, so a
  non-dev admin build's real API host is **not** in its CSP — harmless today only because the
  policy is **Report-Only** (it reports, does not block). Env-templating the admin (and client)
  nginx CSP is already owned by [#89](https://github.com/TiagoJVO/beekeepingit/issues/89) (both
  nginx.conf files carry that note); this entry just records that flipping the admin CSP to
  enforcing **must** wait for that per-environment templating, or a staging/prod admin build
  would block its own API calls. **Not a merge blocker** (Report-Only). Prune once #89 lands the
  templating.

## `feat/organizations-member-lifecycle` (#290 — member remove + role change)

- **Re-invite / re-join after member removal** — enabling member removal (#290, soft
  `status` → `removed`) makes a previously-unreachable edge reachable: if an admin later
  **re-invites a removed member's email** and that user logs in, the accept-on-login path
  (`acceptPendingInvitationByEmail` in `services/organizations/api/invitations.go`) does an
  `INSERT` into `organizations.memberships`, which violates `UNIQUE (organization_id, user_id)`
  because the `removed` row persists — surfacing as a `500` instead of re-activating the
  membership. **Not a merge blocker for #290** (remove + role change only; the removal endpoint
  itself is correct). Re-invite is explicitly still-open detail under D-3. **Fix when re-invite
  is built:** have the accept path **reactivate** an existing `removed` membership (UPSERT /
  `ON CONFLICT (organization_id, user_id) DO UPDATE SET status='active', role=…`) instead of a
  bare `INSERT`. **Promote to a GitHub Issue** and fold into the re-invite/expiry story; prune
  here once referenced.

---

_Aside from the above: PR #418's before-merge item (create the `cluster-ops.yml`
secrets/variables) is done — the `staging-gate` set is in place. `production-gate` secrets are
not owed here: prod is deferred until DR (`Q-DR`) + #90 land (D-26), and the fill-in steps live in
`infra/README.md#secrets--remote-cluster-operations`. The `DEPLOY_NOTIFY_TOKEN` manual step remains
tracked in [#413](https://github.com/TiagoJVO/beekeepingit/issues/413), still open._
