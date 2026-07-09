# 0016 — Replace Keycloak with Authentik, behind a provider-agnostic OIDC boundary

- **Status:** Accepted
- **Date:** 2026-07-10
- **Issue / Epic:** Keycloak→Authentik migration (epic created in WS-E) · **Milestone:** M0
- **Requirements:** NFR-SEC-1, NFR-ROL-1/2, FR-TEN, FR-OF-1, NFR-ARC-2, NFR-CMP, NFR-I18N
- **Decisions:** [D-7](../../requirements/decisions.md#d-7) (revised: Keycloak → Authentik), [D-6](../../requirements/decisions.md) (Postgres), [D-13](../../requirements/decisions.md) (Flux)
- **Supersedes (in part):** the **Keycloak** specifics of [ADR-0004](0004-authn-authz.md) and the
  **Keycloak** deployment in [ADR-0012](0012-keycloak-minio-standalone-helmreleases.md)
- **Contract:** [oidc-integration.md](../architecture/oidc-integration.md) · **Model:** [auth.md](../architecture/auth.md)

## Context

[D-7](../../requirements/decisions.md#d-7) originally chose **Keycloak** as the self-hosted OIDC
IdP, and [ADR-0004](0004-authn-authz.md) designed a two-layer model on top of it (Keycloak for
authN + a coarse global role; app-layer org-scoped authZ owned by the `organizations` service).
The user decided to **replace Keycloak with [Authentik](https://goauthentik.io/)**. Nothing is in
production, so this is the moment to do a **thoughtful** replacement rather than a find-and-replace
that keeps the app shaped around a specific vendor.

Two forces framed the decision:

- **Most of the design is already provider-neutral.** Services are OAuth2 **resource servers** that
  validate any RS256 JWT via **OIDC discovery + JWKS** (`coreos/go-oidc`), driven by neutral env
  vars (`OIDC_ISSUER_URL`, `OIDC_AUDIENCE`, `OIDC_DISCOVERY_URL`). ADR-0004 itself noted Keycloak was
  "swappable for any OIDC IdP." The Keycloak coupling was concentrated in **naming**
  (`keycloak_sub`), the **client's hard-coded URL scheme**, the **realm-import** provisioning, and
  the **`keycloak.*` gateway host**.
- **The two-layer authZ + offline model must not change.** Org membership/role stays app-side
  (`organizations.memberships`), never an IdP concern — so the swap touches *authentication plumbing*,
  not authorization or tenancy.

Three empirical spikes stood Authentik up, drove a real Authorization-Code+PKCE login, and
**validated a live Authentik token through this repo's exact `go-oidc` bridge** — confirming the
backend validation path works **unchanged**.

## Decision

**Adopt Authentik as the v1 OIDC provider, but treat standard OIDC as the contract** — the app
depends only on the discovery document, JWKS, and standard claims, so the IdP is a swappable
deployment detail. The full, frozen interface is [oidc-integration.md](../architecture/oidc-integration.md);
the load-bearing points:

1. **Provider-agnostic boundary.** All OIDC endpoints are read from the issuer's discovery document
   at runtime (backend already does this; the client moves off hard-coded Keycloak paths to
   `openid_client`'s discovery core). One config knob — the **issuer URL** — selects the IdP.
2. **Authentik deployment.** A standalone Flux `HelmRelease` (chart `authentik`, pinned version) with
   **bundled Postgres** (the current chart needs **no Redis**); a wrapper subchart owns the generated
   config/DB Secrets + a **blueprint** ConfigMap (declarative provider/application/group/seed-user,
   the analogue of Keycloak's realm import). Same standalone-release pattern as ADR-0012.
3. **Dedicated `auth.beekeepingit.local` host** for Authentik, separate from
   `app.beekeepingit.local` (PWA + APIs + sync) — avoids Authentik's broad root-path surface
   colliding with the PWA and keeps the app origin cross-origin-isolated for PowerSync.
4. **Claim decisions.** `sub` via **`user_upn`** = an app-assigned **UUID** (stable, immutable,
   non-PII, pinnable for the seed); `aud` = the client id (`beekeepingit-pwa`), so services set
   `OIDC_AUDIENCE=beekeepingit-pwa`. The identity projection column is renamed `keycloak_sub` →
   **`oidc_sub`**.
5. **Standards-based logout.** Front-channel `end_session_endpoint` redirect with `id_token_hint`
   (client persists the `id_token`) + optional token revocation — replacing Keycloak's
   refresh-token POST.
6. **Credential lifecycle stays where it was.** Registration remains disabled; **email
   verification, password reset/recovery, and SMTP** remain **EPIC-14** ([#15](https://github.com/TiagoJVO/beekeepingit/issues/15)).
   The `email_verified` claim is cosmetic in Authentik's default mapping — documented, with
   registration-disabled as the actual control until EPIC-14 hardens it.

## Consequences

**Positive**

- **The IdP is now genuinely swappable** — discovery-driven client + neutral backend + neutral
  naming (`oidc_sub`). A future IdP change is one issuer URL, not a code migration.
- **Backend barely moves** — validation is unchanged; only env values and naming change. Confirmed
  end-to-end against a real Authentik token.
- **Cleaner in-cluster/external split than Keycloak** — Authentik derives the issuer from the request
  host, so internal discovery (no forwarding headers) yields an internal `jwks_uri` while the browser
  token's external `iss` is trusted via the existing bridge — **no `KC_HOSTNAME`-style config**.
- **Declarative, reproducible provisioning** via blueprints, applied idempotently by the worker
  (analogue of `--import-realm`).

**Negative / risks**

- **Client logout is a real behavior change** — a front-channel redirect through the IdP (clears the
  SSO cookie) instead of a silent POST; requires persisting the `id_token`. Updates
  [auth.md §7](../architecture/auth.md) + [ADR-0004](0004-authn-authz.md).
- **New datastore dependency** — Authentik needs its own Postgres (bundled for now; external/CNPG is
  the EPIC-14 target). Heavier and slower to boot than Keycloak `start-dev` → CI budget bumped.
- **`email_verified` is cosmetic by default** — the invitation accept-on-login gate relies on it;
  mitigated by registration-disabled now, hardened in EPIC-14.
- **No recovery flow ships by default** — password reset must be provisioned (EPIC-14).
- **Version sensitivity** — spikes observed behavior across two Authentik versions; the pinned
  version is re-validated end-to-end as the infra workstream's first cluster task.

## Alternatives considered

- **Keep Keycloak.** Rejected — the user chose Authentik; and the swap is cheap because the design
  was already OIDC-standard.
- **Find-and-replace swap (keep the app shaped around the provider).** Rejected — nothing is live, so
  the right move is to decouple (discovery-driven client, neutral naming) so we never pay this cost
  again.
- **Single host with Authentik under path prefixes.** Rejected — Authentik's broad root paths collide
  with the PWA `/` catch-all (the same silent-fallthrough class PowerSync's strip-prefix already
  works around); a dedicated host is cleaner.
- **`user_email` as `sub`.** Rejected — couples the immutable identity key to a mutable PII value; a
  UUID `upn` gives the same seed-reproducibility without that trap.

## Follow-ups

- **Build:** the migration epic + workstream stories (WS-A infra, WS-B backend, WS-C client, WS-D
  docs, WS-E backlog) — created in WS-E.
- **EPIC-14 ([#15](https://github.com/TiagoJVO/beekeepingit/issues/15)):** real `email_verified`
  mapping, recovery/password-reset flow, SMTP, external/CNPG Postgres, secret + security review, and
  the `sub`-`upn` assignment in the real enrollment flow.
- **Docs (WS-D):** [auth.md](../architecture/auth.md), [data-model.md](../architecture/data-model.md),
  [api-contracts.md](../architecture/api-contracts.md), [platform.md](../architecture/platform.md),
  [service-decomposition.md](../architecture/service-decomposition.md),
  [sync.md](../architecture/sync.md), [walking-skeleton.md](../architecture/walking-skeleton.md).
