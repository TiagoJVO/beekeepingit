# OIDC integration contract (v1) — provider-agnostic identity, deployed on Authentik

> **Status:** Frozen contract — Phase 0 of the Keycloak→Authentik migration. This is the
> **seam every workstream builds against**; treat its fixed values as authoritative. Intent:
> [D-7](../../requirements/decisions.md#d-7). Provider-neutral design model:
> [auth.md](auth.md). Decision + rationale: [ADR-0016](../adr/0016-replace-keycloak-with-authentik.md).

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
- **Registration** — disabled (Authentik default; no enrollment flow bound to the app).
- **`platform-operator`** — an Authentik **group** (ops-only marker, **not** an app role); the app authZ path never reads it.

## 4. Subject & audience — the two claim decisions

- **`sub` → `sub_mode: user_upn`.** Each user's `attributes.upn` holds an **app-assigned UUID**;
  `sub` = that UUID — **stable, immutable, non-PII, and reproducible** for the dev/CI seed.
  The **seed user's `upn` = `11111111-1111-4111-8111-111111111111`** (continuity: `oidc_sub`
  keeps its prior value). _Rejected: `user_email` (mutable PII as identity key); `user_uuid` /
  `hashed_user_id` (unpinnable / secret-key-derived → not reproducible)._
  **Forward-requirement (not v1 work):** when real self-service enrollment is built, its flow
  must assign a UUID `upn` per user.
- **`aud` → services expect `beekeepingit-pwa`.** Authentik's default `aud` is the client id, so
  set **`OIDC_AUDIENCE=beekeepingit-pwa`** (no custom audience mapper). A stale value = silent 401s.

## 5. Claims

Present: `sub, iss, aud, azp, exp, iat, email, email_verified, name, given_name (=full name),
preferred_username, groups`. **Absent by default:** `family_name`, `locale`. The app collects
profile (name/locale) during onboarding (FR-ONB-1), so it does **not** depend on IdP profile
claims; add a `locale` scope mapping only if IdP-sourced locale is later wanted (NFR-I18N) —
optional.

> **`email_verified` caveat (security).** Authentik's default email mapping hardcodes
> `email_verified: true` (cosmetic). The invitation accept-on-login gate ([auth.md §8.7](auth.md))
> checks it; with **registration disabled** and admin/invite-provisioned accounts, the
> registration-disabled stance is the **actual** control. Real verification (a mapping reflecting
> true state) + **password reset/recovery** flow + SMTP are **EPIC-14** ([#15](https://github.com/TiagoJVO/beekeepingit/issues/15)).
> Documented — not silently weakened.

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
- **Blueprint** — provider + application + `platform-operator` group + seed user (validated to apply
  clean). `version: 1`, timedelta validities, **object-list `redirect_uris`** with `matching_mode: regex`.
- **Version pin + revalidation** — pin one Authentik version (align chart `appVersion` with the
  validated blueprint). **WS-A's first cluster task = re-run the OIDC end-to-end validation on the
  pin.** Watch: `end_session` behavior ([authentik#19201](https://github.com/goauthentik/authentik/issues/19201)),
  `redirect_uris` object form, the `email_verified` mapping.
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
