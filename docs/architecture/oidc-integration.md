# OIDC integration contract (v1) — provider-agnostic identity, deployed on Authentik

> **Status:** Frozen contract — the migration this defined (Keycloak→Authentik) has since
> **shipped across infra, backend, and client** ([auth.md](auth.md) §8.5-8.9 documents each
> workstream as-built). This remains the **seam every workstream builds against**; treat its
> fixed values as authoritative. Intent: [D-7](../../requirements/decisions.md#d-7). Provider-neutral
> design model: [auth.md](auth.md). Decision + rationale: [ADR-0016](../adr/0016-replace-keycloak-with-authentik.md).

**Requirements:** NFR-SEC-1, NFR-ROL-1/2, FR-TEN, FR-OF-1, NFR-ARC-2, NFR-I18N
**Decisions:** [D-7](../../requirements/decisions.md#d-7) (Authentik + boundary), [D-6](../../requirements/decisions.md) (Postgres)
**ADRs:** [0016](../adr/0016-replace-keycloak-with-authentik.md) (this swap), [0004](../adr/0004-authn-authz.md) (model, provider-neutral), [0012](../adr/0012-keycloak-minio-standalone-helmreleases.md) (deploy pattern)
**Validated by:** the migration spikes (Authentik stood up empirically; a live token verified through the repo's `go-oidc` bridge — `VERIFY_OK`).

---

## 1. Principle — the app depends on OIDC, not on a provider

The application depends **only on standard OIDC**: the **discovery document**
(`/.well-known/openid-configuration`), **JWKS**, and **standard claims** (`iss`, `aud`,
`sub`, `email`, `email_verified`, `name`, `groups`). **No** vendor URL scheme, role model,
admin API, or flow specifics live in application code. **Swapping the IdP = changing the
issuer URL**, nothing more. Authentik is the v1 deployment of this contract; the two-layer
authZ + offline model in [auth.md](auth.md) is provider-neutral and unchanged.

## 2. Topology & hosts (replaces the single `keycloak.beekeepingit.local`)

| Host                               | Serves                                                     |
| ---------------------------------- | ---------------------------------------------------------- |
| **`auth.beekeepingit.local:8443`** | Authentik (issuer + all its paths)                         |
| **`app.beekeepingit.local:8443`**  | PWA (`/`) + Go APIs (`/v1/*`) + PowerSync (`/sync-stream`) |

Dedicated auth host: avoids Authentik's broad root paths (`/api`, `/static`, `/media`, `/-`,
`/if`, root files) colliding with the PWA `/` catch-all, and keeps the app origin
**cross-origin-isolated** (COOP/COEP for PowerSync). OIDC redirects are cross-origin-friendly,
so a separate origin is free of cost here.

## 3. Provider (Authentik application + OAuth2 provider)

- **Application slug** `beekeepingit` → **issuer** `https://auth.beekeepingit.local:8443/application/o/beekeepingit/` (`issuer_mode: per_provider`, request-host-derived).
- **Client** `beekeepingit-pwa` — **public**, **Authorization Code + PKCE (S256)**, **RS256**.
- **Grant types** — `authorization_code`, `refresh_token`. **Set explicitly** — on Authentik 2026.5.x this defaults to `[]` (no grants), which rejects the authorize request with `invalid_request`.
- **Token validity** — access **15m**, refresh **30d** (blueprint uses Django-timedelta strings: `minutes=15`, `days=30`).
- **Redirect URIs** — `http://localhost:.*` (regex), `https://app\.beekeepingit\.local:8443/.*` (regex), **and** `https://app.beekeepingit.local:8443` (**strict**). The strict bare-origin entry is required because the PWA sends the bare origin as its `redirect_uri`, and Authentik derives **CORS**-allowed origins from `redirect_uris` — an `Origin` has no path, so the `…/.*` regex never matches it.
- **Registration** — **self-service enrollment since #366** ([auth.md §8.11](auth.md)): blueprint
  flow `beekeepingit-enrollment`, linked from the login page via the default identification
  stage's `enrollment_flow`. Registrations are held **unverified** on an emailed one-time link
  (the #361 machinery) and a UUID `upn` is assigned at creation (§4). The provider/client
  contract above is unchanged — enrollment is IdP-side flow config.
- **`platform-operator`** — an Authentik **group** (ops-only marker, **not** an app role); the app authZ path never reads it.

## 4. Subject & audience — the two claim decisions

- **`sub` → `sub_mode: user_upn`.** Each user's `attributes.upn` holds an **app-assigned UUID**;
  `sub` = that UUID — **stable, immutable, non-PII, and reproducible** for the dev/CI seed.
  The **seed user's `upn` = `11111111-1111-4111-8111-111111111111`** (continuity: `oidc_sub`
  keeps its prior value). _Rejected: `user_email` (mutable PII as identity key); `user_uuid` /
  `hashed_user_id` (unpinnable / secret-key-derived → not reproducible)._
  **Forward-requirement — implemented by #366:** the self-service enrollment flow assigns a UUID
  `upn` per user at creation (an expression policy on its `user_write` binding, fail closed: no
  account is created without one — [auth.md §8.11](auth.md)).
- **`aud` → services expect `beekeepingit-pwa`.** Authentik's default `aud` is the client id, so
  set **`OIDC_AUDIENCE=beekeepingit-pwa`** (no custom audience mapper). A stale value = silent 401s.

## 5. Claims

Present: `sub, iss, aud, azp, exp, iat, email, email_verified, name, given_name (=full name),
preferred_username, groups`. **Absent by default:** `family_name`, `locale`. The app collects
profile (name/locale) during onboarding (FR-ONB-1), so it does **not** depend on IdP profile
claims; add a `locale` scope mapping only if IdP-sourced locale is later wanted (NFR-I18N) —
optional.

> **`email_verified` is REAL state since #361** ([auth.md §8.10](auth.md), ADR-0019). Authentik's
> built-in email mapping hardcodes the claim (`true` before upstream 2025.10, `false` on the
> pinned 2026.5.4 — either way cosmetic; the hardcoded `false` also meant the invitation
> accept-on-login gate ([auth.md §8.7](auth.md)) could never fire live). The provider now uses a
> **custom scope mapping** emitting the `email_verified` **user attribute**, which a login-time
> email-verification stage in the authentication flow sets on completion of the emailed one-time
> link; self-service email changes are **disabled** (`default_user_change_email` false — upstream
> default at 2026.5.4, e2e-pinned; [auth.md §8.10](auth.md)), so a verified address cannot be
> self-re-pointed. Self-service **registration** (since #366, [auth.md §8.11](auth.md)) rides the
> same machinery — a fresh registration is held on the emailed link and can never start verified.
> **Password reset/recovery** flow remains **EPIC-14**
> ([#15](https://github.com/TiagoJVO/beekeepingit/issues/15)) — SMTP, its prerequisite, is now in
> place (`AUTHENTIK_EMAIL__*` from the umbrella's config Secret; dev/CI: the `mailpit` sink).

## 6. Backend contract (Go services)

- **Validation unchanged** — `coreos/go-oidc` via discovery + JWKS; the `InsecureIssuerURLContext`
  bridge stays. Fetch discovery from the **internal** Service URL (no forwarding headers) so the
  doc returns an **internal `jwks_uri`** (reachable in-cluster) while trusting the **external** `iss`.
- **Env:**
  - `OIDC_ISSUER_URL` = `https://auth.beekeepingit.local:8443/application/o/beekeepingit/`
  - `OIDC_DISCOVERY_URL` = `http://authentik-server/application/o/beekeepingit/` — the issuer **base**, _not_ the full `.well-known` URL: `go-oidc`'s `NewProvider` appends `/.well-known/openid-configuration` itself (a full URL here double-appends → 404)
  - `OIDC_AUDIENCE` = `beekeepingit-pwa`
- **Identity naming (provider-neutral):** `identity.users.keycloak_sub` → **`oidc_sub`**;
  `GetUserByKeycloakSub` → `GetUserByOidcSub`; regenerate sqlc; `devseed.KeycloakSub` →
  `OidcSub` = the seed `upn` UUID.

## 7. Client contract (Flutter web PWA)

- **Discovery-driven** — one knob **`OIDC_ISSUER`** (the auth-host issuer); every endpoint read
  from the cached `.well-known` doc. `GATEWAY_BASE_URL` (app host) is for APIs/sync only.
- **Library** — `openid_client` **core** (`Issuer.discover` + `Flow.authorizationCodeWithPKCE`)
  behind the existing `AuthPlatform` seam. **Not** `openid_client_browser` (implicit flow).
- **Logout** — persist the **`id_token`**; front-channel **GET** to `end_session_endpoint` with
  `id_token_hint` + `post_logout_redirect_uri` (clear local state **first** for offline-degrade);
  optional `revocation_endpoint`. Replaces the Keycloak refresh-token POST.
- **Account (password change)** — `OIDC_ACCOUNT_URL` = `https://auth.beekeepingit.local:8443/if/user/#/settings` (a config value, not a derived path).
- **Token storage & offline-first boot (#390)** — the refresh token + `id_token` persist in
  **`localStorage`** (survives a browser restart); the PKCE `code_verifier`/`state` stay in
  per-tab **`sessionStorage`** (ephemeral, single-flow — no reason to outlive the redirect). A
  first boot after upgrading past #390 migrates a token still sitting in the old sessionStorage
  location into localStorage rather than dropping the session. On boot, a stored session that
  fails to refresh for a **network** reason (offline/DNS/timeout — discovery + the refresh-token
  grant are bounded together by a 5s timeout, `_kAuthNetworkTimeout`) still resolves to a
  **stale placeholder session** (empty access token, forced-expired) so the app opens into the
  local-data shell against already-synced PowerSync data; only a provider-rejected refresh
  (`OpenIdException`, e.g. `invalid_grant`/expired) clears the stored session and routes to
  `/login` — and never wipes the on-device local store (that wipe stays exclusive to explicit
  logout / membership-loss purge, sync.md §3.5). The onboarding gate's profile/organization
  checks (`GET /v1/profile`, `GET /v1/organizations/me`) mirror this: each repository caches its
  last-known-good response and serves it back on a network failure so a previously-onboarded
  user isn't bounced to `/profile`/`/organization/new` while offline. `localStorage` is
  XSS-readable — an accepted, documented trade-off for this offline-first PWA stage ahead of the
  hardened BFF/httpOnly-cookie flow **EPIC-14** owns (auth.md §6.4/§6.5 describe that longer-term
  design; this section describes what ships today).

## 8. Deployment (infra)

- **Authentik = standalone Flux `HelmRelease`** (chart `authentik` @ a **pinned version**, repo
  `https://charts.goauthentik.io`), **not** nested in the umbrella — same pattern as
  [ADR-0012](../adr/0012-keycloak-minio-standalone-helmreleases.md). **Bundled Postgres; no Redis**
  (dropped in the current chart). Bitnami image risk does not bite (chart pins official `postgres`).
- **Wrapper subchart** `infra/helm/beekeepingit/charts/authentik/` generates:
  `Secret beekeepingit-authentik-config` (`secret_key`, bootstrap creds, `AUTHENTIK_POSTGRESQL__*`),
  `Secret beekeepingit-authentik-postgresql` (`password`), `ConfigMap beekeepingit-authentik-blueprint`
  (delivered via `blueprints.configMaps` → worker file-discovery). Set
  `authentik.existingSecret.secretName: beekeepingit-authentik-config`.
- **Gateway** — `auth.` host → `authentik-server:80`; `app.` host routes unchanged bar the rename.
- **Blueprint** — provider + application + `platform-operator` group + seed users (validated to apply
  clean). `version: 1`, timedelta validities, **object-list `redirect_uris`** with `matching_mode: regex`.
  Since #361 it also declares the custom `email` scope mapping (real `email_verified`) and the
  login-time email-verification stages/policies; self-service email change stays disabled by the
  upstream `default_user_change_email` default, deliberately NOT a blueprint entry (the Tenant
  model is not blueprint-manageable) — see [auth.md §8.10](auth.md). Since #366 it additionally
  declares the self-service **enrollment flow** `beekeepingit-enrollment` (prompts + length-only
  password policy, upn-assigning `user_write`, the reused email/stamp stages, the default
  user-login stage) and links it from the default identification stage's `enrollment_flow` —
  see [auth.md §8.11](auth.md).
- **Version pin + revalidation** — pin one Authentik version (align chart `appVersion` with the
  validated blueprint). **WS-A's first cluster task = re-run the OIDC end-to-end validation on the
  pin.** Watch: `end_session` behavior ([authentik#19201](https://github.com/goauthentik/authentik/issues/19201)),
  `redirect_uris` object form, the `email_verified` mapping (now blueprint-owned, #361 — a version
  bump must not resurrect the managed built-in on the provider), the default authentication
  flow's stage-binding shape the #361 entries splice into, **`default_user_change_email` staying
  disabled** (upstream `Tenant` default `false` at 2026.5.4, `tenants/models.py` lines 64–66 —
  not blueprint-pinnable, the Tenant model is `InternallyManagedMixin`-excluded from blueprint
  management, so the pin is the version pin + the e2e in
  `client/e2e/tests/verification.spec.ts` asserting the email-change rejection live; if a bump
  flips the default or ops ever enable it deliberately, a reset-on-change policy on the
  user-settings write binding becomes **mandatory** — recover it from PR #411 history and
  re-verify the binding identifiers, which at 2026.5.4 were
  `flow-default-user-settings-flow.yaml` lines 144–148: `order: 100`) — flow-email
  localization (2026.5.4 renders flow-triggered mail per the request's negotiated language and
  can never reach the shipped `pt_PT` catalog — [auth.md §8.10](auth.md),
  [#412](https://github.com/TiagoJVO/beekeepingit/issues/412); re-check whether a bump fixes
  `User.locale()`'s in-request ordering or adds a negotiable `pt-pt`; the flow-executor **web**
  catalogs similarly ship `pt-BR` but no `pt-PT`, so the enrollment UI renders English for a
  pt-PT browser) — and the **enrollment-flow splice points (#366,
  [auth.md §8.11](auth.md))**: the default identification stage's `enrollment_flow` link and
  the reused `default-authentication-login` stage must survive a bump; the email stage's
  per-send uuid4-embedding flow-token identifiers must stay per-send (a regression to a shared
  identifier would make concurrent enrollment/login-verification links clobber each other);
  the prompt serializer admitting only declared fields plus `user_write`'s `groups`/`pk` deny
  and unknown-key discard are the enrollment write-safety boundary (re-verify on bump, the #170
  shape); and identification resolves duplicate emails first-match (accounts registered here
  always have a unique username to identify by — re-check if `user_fields` ever changes).
- **CI** — `helm-e2e`: timeout 20→30m, install `--timeout` →15m, apply the Authentik `HelmRelease`
  - `rollout status` before `helm test`; `helm test` hook curls `/-/health/ready/`. `helm-ci`: swap
    the `codecentric` repo add for the `authentik` repo where a lint/template needs it.

## 9. Cluster access during implementation (coordinator semaphore)

The shared **local dev cluster is a single-writer resource**. Any live-cluster op (`kubectl apply`,
`helm upgrade/install/test`, `flux reconcile`, `k3d` up/down, live Playwright e2e) runs **only**
under the coordinator-held token: agent sends **`CLUSTER-REQUEST`** (purpose + est. duration) and
pauses → coordinator green-lights **one at a time** → agent sends **`CLUSTER-RELEASED`** on
finish/fail. Offline work (code, `helm template`/`lint`, Go testcontainer integration tests, Flutter
unit tests, docs, backlog) needs **no** token.

## 10. Workstream ownership & final gate

| WS                   | Owns                                                    | Touches cluster    |
| -------------------- | ------------------------------------------------------- | ------------------ |
| **A — Infra/Deploy** | `infra/**`, `.github/workflows/helm-*.yml`              | ✅ (semaphore)     |
| **B — Backend**      | `services/**`                                           | ❌                 |
| **C — Client**       | `client/**`                                             | e2e ✅ (semaphore) |
| **D — Docs**         | `docs/**`, `README.md`, `CLAUDE.md`, requirements sweep | ❌                 |
| **E — Backlog**      | GitHub Issues, `FOLLOWUPS.md` (coordinator-run)         | ❌                 |

Shared files are single-owner to avoid conflicts: `README.md`/`CLAUDE.md`/all `docs/**` → **WS-D**;
`FOLLOWUPS.md` + GitHub → **WS-E/coordinator**. **Final gate:** `grep -ri keycloak` == 0.
