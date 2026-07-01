# 0004 — AuthN via Keycloak (JWKS-validated JWT) + app-layer org-scoped authZ

- **Status:** Accepted
- **Date:** 2026-07-01
- **Issue / Epic:** #109 / #103 (EPIC-DESIGN) · **Milestone:** M0
- **Requirements:** NFR-SEC-1, NFR-ROL-1, NFR-ROL-2, FR-TEN-1, FR-TEN-2, FR-ONB-1/2/3, FR-OF-1
- **Decisions:** [D-7](../../requirements/decisions.md#d-7--identity--auth-keycloak-self-hosted)
  (Keycloak), [D-3](../../requirements/decisions.md) (org creator = admin), [D-10](../../requirements/decisions.md) (PWA-first)
- **Open questions:** [Q-AUTH](../../requirements/open-questions.md) (resolved),
  [Q-ROLE](../../requirements/open-questions.md) (resolved), [Q-TEN](../../requirements/open-questions.md)
- **Design doc:** [auth.md](../architecture/auth.md)

## Context

[D-7](../../requirements/decisions.md#d-7--identity--auth-keycloak-self-hosted) sets the mechanism —
**Keycloak** (OIDC), **offline token caching**, and **app-level org-scoped authorization** on top —
but leaves the detail to design. Two prior EPIC-DESIGN decisions **depend on that detail**:
[ADR-0002](0002-multi-tenancy.md) makes app-layer scoping the primary tenancy control and explicitly
defers *"how `organization_id` is derived from the token + membership"* to #109, and
[service-decomposition.md](../architecture/service-decomposition.md) leaves *"JWT validation at the
edge and/or per service"* and the **Q-ROLE** admin-scope question to #109.

The forces to reconcile:

- **Org access is per-organization, but Keycloak roles are global to a user.** A person may be
  **admin of one org and a plain user of another** in the multi-org future
  ([C-1](../../requirements/context.md#c-1--single-organization-now-multi-organization-later)).
- **Membership and ownership are domain data** owned by the `organizations` service (FR-TEN) and
  **change frequently** (invite/remove/promote) — putting them in the IdP or the token risks
  **staleness**, especially with **cached/offline** tokens.
- **Field-first, offline** (FR-OF-1, D-10): the app must open and work without connectivity, yet the
  **server must stay authoritative** for writes.

## Decision

Adopt a **two-layer** model — Keycloak for authentication + a coarse global role, and an
**app-layer, org-scoped** authorization check owned by the application:

1. **Keycloak = authN + identity.** One realm `beekeepingit`; **public + PKCE** clients for the PWA
   and Admin App; **domain services are resource servers**. Keep only a **coarse global role**
   (optional `platform-operator` for ops); **end users carry no org role in Keycloak**.
2. **JWT validation via JWKS in the shared Go middleware**, run by **every service** (not only the
   edge): verify **signature (RS256), `iss`, `aud`, `exp/nbf`** against **cached JWKS** (refreshed on
   rotation / unknown `kid`). Defense in depth — the gateway may also validate.
3. **App-layer org-scoped authZ is the real access control.** The `admin`/`user` role (NFR-ROL-1)
   is the **membership** role in `organizations.memberships`, resolved **per request** — the
   `organization_id` is **derived server-side** from the caller's membership, **never a client
   parameter** (an org id in an org-management path is *asserted* against membership, never
   widening — [api-contracts.md §9](../architecture/api-contracts.md#9-auth--tenancy-in-the-contract-d-7-adr-0002)).
   The middleware maps **`sub` → user → active membership → `organization_id` + role**; **no active
   membership ⇒ 403**, an **out-of-scope resource ⇒ 404**. That `organization_id` **feeds the
   multi-tenancy model** ([ADR-0002](0002-multi-tenancy.md)): every query is org-scoped (+ optional
   RLS), and the sync slice is org-scoped.
4. **Org/role are deliberately NOT in the token** — they are resolved from the **database** so the
   `organizations` service stays authoritative and cached/offline tokens don't grant stale access.
5. **`admin` is org-scoped** (D-3) — manages members, roles, org settings, invitations (later
   quotas); `user` does field CRUD + AI + history. Data isolation is **organization-level**
   (FR-TEN-2 / Q-TEN): members share org data; every change records the actor (FR-HIS). **This
   resolves [Q-ROLE](../../requirements/open-questions.md).**
6. **Offline login = local grace window, not a server bypass.** On online login, cache (in **secure
   storage**) the **refresh/access tokens, JWKS, and identity**. Offline, a **valid or
   within-grace** token is **validated locally against cached JWKS** to unlock **reads + queued
   writes**; queued writes are **re-authorized by the server at sync** (ADR-0002, D-12). Grace window
   **≈ 14–30 days** (tunable). **PWA phase** relies on refresh-token reuse (fresh login still needs
   online); **full offline login is native-phase** (D-10). Token lifetimes and the grace value are
   **proposals** to confirm in **EPIC-14** (#15). **This resolves the offline half of
   [Q-AUTH](../../requirements/open-questions.md)**; verification/reset use **Keycloak built-ins**.

Full specification, diagrams, and the capability matrix are in the
[design doc](../architecture/auth.md).

## Consequences

**Positive**

- **Single source of truth per concern:** identity in Keycloak, **org authorization in the
  `organizations` DB** — no membership duplication into the IdP, no stale-token access. Directly
  realizes D-7's "app-level org-scoped authorization."
- **Multi-org ready with no redesign** (C-1): per-request active-org + membership resolution already
  supports a user belonging to many orgs with different roles; single-org v1 is the trivial case.
- **Produces the tenancy key ADR-0002 needs:** the middleware is the **one place** `organization_id`
  is derived, so app-scoping, optional RLS, and the sync slice all key off a single, tested control —
  and it's **enforceable + testable** (cross-org attempts, admin-only ops → [#28](https://github.com/TiagoJVO/beekeepingit/issues/28), NFR-TST).
- **Standard OIDC + JWKS per service** keeps services stateless and zero-trust; Keycloak stays
  swappable for any OIDC IdP (NFR-ARC-2) and **social/SSO-ready** later.
- **Offline works without weakening the server:** tenancy holds on-device via the org-scoped slice,
  and the server re-authorizes every write at sync — offline is a **UX** affordance, not an authz
  hole.

**Negative / risks**

- **Per-request membership lookup** on the hot path. **Mitigation:** short-TTL per-instance cache
  keyed by (user, org), invalidated on membership change; the read path (call `organizations` vs a
  replicated projection) is a build choice for [#28](https://github.com/TiagoJVO/beekeepingit/issues/28)/[#108](https://github.com/TiagoJVO/beekeepingit/issues/108).
- **Eventual revocation offline:** a removed/disabled member keeps **local** access until the grace
  window lapses or they reconnect. **Mitigation:** they gain nothing server-side (writes rejected at
  sync); grace window is bounded and tunable. Accepted trade-off for a field-first app.
- **Client trust for local validation:** offline validity is judged on-device. **Mitigation:** tokens
  live only in the secure enclave; a compromised device is EPIC-14's threat model; the server never
  trusts the client for authorization.
- **PWA token persistence (esp. iOS)** may drop the cached session, forcing re-login. Tracked by
  **SP-1** PWA-persistence ([#54](https://github.com/TiagoJVO/beekeepingit/issues/54)); iOS is last
  anyway (D-10).

## Alternatives considered

- **Per-org roles/permissions inside Keycloak** (realm roles per org, Groups, or Keycloak
  Authorization Services). **Rejected for v1:** couples domain membership (owned by `organizations`)
  into the IdP, multiplies Keycloak objects per org, and goes stale against cached/offline tokens —
  for a model our app-layer check does more simply and testably. Reachable later if IdP-side policy
  becomes worthwhile.
- **Embed `organization_id` + role as token claims** (via a Keycloak protocol mapper that reads
  membership). **Rejected:** re-introduces staleness (membership changes mid-token-life), forces a
  mapper→`organizations` coupling, and complicates multi-org "active org" selection. The DB stays
  authoritative instead.
- **Edge-only JWT validation** (trust the gateway, services skip it). **Rejected:** breaks zero-trust
  between services; a bug or internal caller could bypass authz. Kept as an **optional** fast-fail
  layer **in addition to** per-service validation.
- **ReBAC now (OpenFGA / Ory Keto)** for fine-grained/relationship access. **Deferred:** unnecessary
  for org-level isolation in v1; slots in after authN when cross-org sharing or per-resource ACLs
  appear (design doc §5.5). Noted in [tech-stack.md](../../requirements/tech-stack.md#identity--keycloak).

## Follow-ups

- **Build:** [#24](https://github.com/TiagoJVO/beekeepingit/issues/24) (Keycloak realm/client + OIDC
  login), [#28](https://github.com/TiagoJVO/beekeepingit/issues/28) (roles + org-scoped middleware —
  consumes this design), [#30](https://github.com/TiagoJVO/beekeepingit/issues/30) (tenancy
  enforcement — consumes the derived `organization_id`).
- **EPIC-14 ([#15](https://github.com/TiagoJVO/beekeepingit/issues/15)):** realm config, SMTP
  (verification/reset), secret management, and **security sign-off** on token lifetimes + grace
  window.
- **Consolidation:** [#110](https://github.com/TiagoJVO/beekeepingit/issues/110) (walking-skeleton
  design) wires login → create → offline edit → sync end-to-end using this model.
- **Resolved open questions:** removes **Q-AUTH** and **Q-ROLE** from
  [open-questions.md](../../requirements/open-questions.md); their answers now live here + in the
  [design doc](../architecture/auth.md).
