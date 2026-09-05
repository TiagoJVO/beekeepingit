# 0020 — Admin app on its own host + cross-origin CORS in the service template

- **Status:** Accepted
- **Date:** 2026-07-25
- **Requirements:** FR-TEN-2 (optimistic concurrency), NFR-SEC-1, NFR-ARC-2 (swappable
  ingress controller)
- **Decisions:** builds on [ADR-0016](0016-replace-keycloak-with-authentik.md) (the
  app/auth host split), [D-5](../../requirements/decisions.md#d-5)
- **Design:** [`docs/architecture/oidc-integration.md §2`](../architecture/oidc-integration.md),
  [`docs/architecture/admin-app.md §9`](../architecture/admin-app.md)
- **Issue:** [#449](https://github.com/TiagoJVO/beekeepingit/issues/449) (admin scaffold
  [#72](https://github.com/TiagoJVO/beekeepingit/issues/72), org edit
  [#73](https://github.com/TiagoJVO/beekeepingit/issues/73))

## Context

The React admin app ([#72](https://github.com/TiagoJVO/beekeepingit/issues/72)) reads an org
via `GET /organizations/me` and writes via `PATCH /organizations/{orgId}` with `If-Match`
optimistic concurrency (FR-TEN-2), echoing the `ETag` from the read. It was scaffolded and
CI-built but **not deployed**: the gateway only routed the PWA (`/`) and the Go APIs (`/v1/*`)
on the app host (ADR-0016), and there was **no CORS anywhere** in `services/` or the gateway.

Two things follow from that gap:

1. **No serving topology.** The admin app needs a home behind the gateway. Folding it onto the
   app host under a sub-path would collide with the PWA `/` catch-all and force COOP/COEP
   negotiation the admin app (online-only, no PowerSync) does not want.
2. **Cross-origin ETag is invisible.** Served from any origin other than the app host, the admin
   app's `fetch()` is cross-origin, and browsers hide non-simple response headers (like `ETag`)
   from JavaScript unless the server sends `Access-Control-Expose-Headers: ETag`. Without it
   `getWithETag` reads `etag: null`, #73's client fail-safe blocks every save, and even the
   initial `GET` fails its preflight. The edit feature is unusable cross-origin.

## Decision

### 1. Serve the admin app on its own host (maintainer-confirmed)

`admin.beekeepingit.local:8443` in dev, mirrored per environment (`gateway.adminHost`), exactly
like the existing app/auth split (ADR-0016). As-built:

- A new **`admin` Helm subchart** (Deployment + Service behind nginx), mirroring the `pwa`
  subchart.
- A **gateway Ingress rule** for `adminHost` → the `admin` Service, and `adminHost` added to the
  gateway's self-signed **TLS Secret SAN** (one Secret still terminates every host).
- The admin image's `VITE_*` (issuer → auth host, API base → app host,
  `VITE_OIDC_CLIENT_ID=beekeepingit-admin`, account URL → auth host) are **build-time** Vite
  constants, so they are baked per environment: `build-publish.yml` bakes the dev URLs into
  `admin:latest`, and `release-deploy.yml`'s `publish-admin` job bakes staging/prod. The
  `deploy-urls` drift check guards those against the helm overlays.

### 2. CORS lives in the shared service template, not the gateway

A **CORS middleware in `services/servicetemplate/cors`**, wired into every service's router by
`servicetemplate.New`, configured by `CORS_ALLOWED_ORIGINS` (per environment from
`global.adminOrigin`). For an allowed origin it echoes the origin (never `*` — credentials are
allowed), sets `Access-Control-Allow-Credentials: true` and
**`Access-Control-Expose-Headers: ETag`**, and answers the preflight `OPTIONS` with `204` ahead
of JWT auth, advertising `Access-Control-Allow-Methods` (incl. `PATCH`/`DELETE`) and
`Access-Control-Allow-Headers` (incl. `Authorization`/`If-Match`/`Content-Type`).

The IdP **audience** contract is untouched: services still validate
`OIDC_AUDIENCE=beekeepingit-pwa`. The admin app is a distinct OIDC **client**
(`beekeepingit-admin`, provisioned by the Authentik blueprint,
[#456](https://github.com/TiagoJVO/beekeepingit/issues/456)) — a separate concern from token
audience validation.

## Consequences

- Every service inherits identical CORS with zero per-service code; a new service that adopts the
  template is covered for free.
- The gateway stays a plain, controller-agnostic `networking.k8s.io/v1` Ingress (**NFR-ARC-2**) —
  no Traefik-only CORS middleware annotation that a controller swap would silently drop.
- CORS is **default-off**: an empty allowlist emits no CORS headers (same-origin only), so no
  service is accidentally opened to arbitrary origins.
- Adding an origin is a values change (`global.adminOrigin`), not a code change.
- A third host means a third hostname to keep in step across two repos. "Mirrored per
  environment" is only true once the **deployed** values in `beekeepingit-gitops`
  (`apps/<env>/beekeepingit-helmrelease.yaml`, D-27/ADR-0018) carry `gateway.adminHost` — this
  repo's `environments/<env>.yaml` is a mirror, not the source. Staging got only the mirror, so
  its cert-manager Certificate asked a public CA for the dev default
  `admin.beekeepingit.local`, drew `400 urn:ietf:params:acme:error:rejectedIdentifier`, and
  renewal was dead for five weeks ([#556](https://github.com/TiagoJVO/beekeepingit/issues/556)).
  The gateway chart now refuses to render a `.local`/`.localhost` value — in `gateway.appHost` /
  `authHost` / `adminHost` **and** in `global.appOrigin` / `global.adminOrigin`, since the latter
  two become credentialed CORS allowlist entries and OIDC redirect URIs — when cert-manager is
  enabled (`gateway.assertPublicHostnames`), so the drift fails loudly at render time. It also
  fails when `global.adminOrigin` is set while `gateway.adminHost` is empty, which would otherwise
  be a silent way to satisfy the guard and leave the admin app unreachable.
- Turning the admin host on is a **strictly ordered** operation, because the guard sees values but
  not DNS: (1) set the `ADMIN_HOST` gate-environment variable, (2) run `cluster-ops` `up`/
  `scale-up` so the Cloudflare A record is actually created, (3) add `gateway.adminHost` **and**
  `global.adminOrigin` to the gitops `apps/<env>/beekeepingit-helmrelease.yaml`, (4) only then
  promote a chart carrying the guard. Adding the host before the A record exists merely trades the
  `rejectedIdentifier` rejection for a failed HTTP-01 challenge, and one failed authorization
  invalidates the whole multi-SAN order — taking the app and auth certificates down with it.
  Staging has no `admin.` A record yet; `ADMIN_HOST` is an optional per-gate-environment variable.

## Alternatives considered

- **Traefik `Middleware` CORS annotation on the Ingress** — rejected: not controller-agnostic
  (NFR-ARC-2); the gateway is deliberately a plain Ingress so the controller can be swapped.
- **CORS in each service's own handler code** — rejected: duplicated, drift-prone, and easy to
  forget on a new endpoint; the template is the one place every service already shares.
- **Serve the admin app under an app-host sub-path (same origin, no CORS needed)** — rejected:
  collides with the PWA `/` catch-all and couples the admin app to the app origin's COOP/COEP
  isolation; a dedicated host matches the established app/auth split (ADR-0016) and was
  maintainer-confirmed.
