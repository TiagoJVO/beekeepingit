# 0010 — Platform backing-services provisioning: vendored charts, CNPG, Traefik reuse

- **Status:** Accepted — the IdP/`minio` vendoring approach below (wrapper charts nesting
  the vendored dependency) is **superseded by
  [ADR-0012](0012-keycloak-minio-standalone-helmreleases.md)** (standalone HelmReleases);
  the IdP itself was later **swapped Keycloak → Authentik** by
  [ADR-0016](0016-replace-keycloak-with-authentik.md), so the historical `keycloak` subchart
  references below now read as **Authentik** (`charts/authentik/`). `postgres`/`gateway`/CNPG/
  Traefik/TLS are unaffected and still stand.
- **Date:** 2026-07-04
- **Issue / Epic:** #84 · EPIC-13 (#83) · **Milestone:** M0
- **Requirements:** NFR-ARC-2, NFR-ARC-3, NFR-SEC
- **Decisions:** [D-6](../../requirements/decisions.md) (Postgres + PostGIS, schema-per-service),
  [D-7](../../requirements/decisions.md) (OIDC IdP — Authentik in v1), [D-1](../../requirements/decisions.md) (single
  cluster, full microservices)
- **Settles:** the open "Traefik or NGINX ingress" in
  [tech-stack.md](../../requirements/tech-stack.md#infrastructure)

## Context

[Issue #84](https://github.com/TiagoJVO/beekeepingit/issues/84) is the first real workload for the
EPIC-13 Helm umbrella chart (`infra/helm/beekeepingit/`), which until now only proved its
subchart-wiring mechanism via a throwaway `charts/smoke/` placeholder. `docs/architecture/
service-decomposition.md` §7 names the four platform subcharts it owns — `postgres`, `keycloak`,
`minio`, `gateway` — but left several implementation choices open: how each subchart is _built_
(hand-rolled, like `smoke`, vs. vendoring a maintained upstream chart), which Postgres delivery
mechanism satisfies D-6, which ingress controller settles `tech-stack.md`'s "Traefik or NGINX",
and how TLS is obtained for the gateway AC. This ADR records those choices.

## Decision

**Vendor real upstream Helm charts where one exists and is well-maintained; hand-roll only where
there's a genuine reason (`gateway`, and the CR/Secrets layer of `postgres`).**

| Subchart   | Approach                                                                                                                                                                                                                                                                                                                                               |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `postgres` | **CloudNativePG (CNPG)** operator (CNCF sandbox, maintained by EDB) — not a plain StatefulSet chart. The `postgres` subchart itself is hand-rolled (a `Cluster` CR + per-service credential Secrets), because CNPG's own chart _is_ the operator, not a per-instance chart.                                                                            |
| `keycloak` | ~~Vendors community **`codecentric/keycloakx`**, wrapped by our own thin chart that adds a generated admin credential + the dev/CI-grade realm import.~~ **Superseded by ADR-0012**: Keycloak is now its own standalone Flux `HelmRelease` sourced from `codecentric/keycloakx` directly; this subchart only keeps the supplementary Secret/ConfigMap. |
| `minio`    | ~~Vendors the **official `charts.min.io` MinIO Inc. chart**, wrapped the same way for a generated root-credentials Secret.~~ **Superseded by ADR-0012**: MinIO is now its own standalone Flux `HelmRelease`; this subchart only keeps the supplementary root-credentials Secret.                                                                       |
| `gateway`  | Hand-rolled — it's just a portable `Ingress` + a self-signed TLS `Secret`; there's nothing to vendor.                                                                                                                                                                                                                                                  |

### Why CNPG over a plain chart, and where the operator lives

CNPG gives first-class **PostGIS support** (its own maintained `ghcr.io/cloudnative-pg/postgis`
operand images — confirmed via `cloudnative-pg/postgis-containers`) and **declarative role
management** (`spec.managed.roles`), which is exactly D-6's "schema per service" shape: one schema
and one least-privilege login role per future domain service
([`data-model.md`](../architecture/data-model.md) §4), provisioned via `postInitApplicationSQL`
and `spec.managed.roles` in `infra/helm/beekeepingit/charts/postgres/templates/cluster.yaml`.

CNPG's declarative roles do **not** auto-generate passwords — the referenced
`kubernetes.io/basic-auth` Secret must pre-exist — so `charts/postgres/templates/secrets.yaml`
generates one per schema via Helm's `lookup` (preserve on `helm upgrade`) + `randAlphaNum`
(generate on first install) idiom, never a literal value in git (NFR-SEC). The same idiom is used
for the Keycloak admin password, the MinIO root credentials, and the gateway's self-signed cert.

The **operator itself is cluster-scoped** (its CRDs/controller aren't per-environment), so unlike
the other three subcharts it is **not** a `Chart.yaml` dependency of the per-environment umbrella
release — installing/upgrading it every `helm upgrade beekeepingit` (or removing it on `helm
uninstall`) would be wrong for something meant to serve every environment on the cluster. Instead
it's installed once via `infra/cluster/up.sh`, the same way k3d already bundles Traefik as a
cluster-level prerequisite the umbrella chart doesn't own.

### Wrapper-chart pattern for `keycloak`/`minio` — superseded, see ADR-0012

_This section describes the original #84 approach, kept for history — it no longer reflects what's
deployed; see [ADR-0012](0012-keycloak-minio-standalone-helmreleases.md)._

Values files aren't templated (only `templates/` are), so a subchart we don't author can't be made
to consume our shared `global.resources.<tier>` lookup — that only works inside templates we own.
Vendoring `keycloakx`/`minio` as **direct** umbrella dependencies would also leave nowhere to put
the generated-credential Secret and realm-import ConfigMap each one needs. Both problems are
solved the same way: a thin **local wrapper chart** (`charts/keycloak/`, `charts/minio/`) that
declares the real upstream chart as its _own_ nested dependency and adds our supplementary
templates alongside it. The umbrella only ever sees the wrapper.

### Gateway: reuse Traefik, portable `Ingress`, self-signed TLS

k3d already runs Traefik as the cluster's ingress controller/load balancer
([`docs/architecture/platform.md`](../architecture/platform.md)). Installing a second controller
(e.g. NGINX) would just add operational surface for no benefit, so **Traefik is the chosen
answer** to `tech-stack.md`'s open "Traefik or NGINX" — settled here, not re-litigated per
change. The `gateway` subchart uses a plain `networking.k8s.io/v1 Ingress` (`ingressClassName:
traefik`), not Traefik's `IngressRoute` CRD, so the controller stays swappable later (NFR-ARC-2).

TLS uses Helm's **built-in `genSelfSignedCert`** (no cert-manager dependency) rather than a
trusted CA. The issue's own notes scope "TLS hardening" to EPIC-14, not #84 — a self-signed
dev/CI cert satisfies "routes traffic over TLS" without pulling in a new dependency for
infrastructure that will be replaced (or fronted by a real CA) when EPIC-14 lands.

## Consequences

**Positive**

- Reuses proven, maintained upstream projects for the hard parts (Postgres HA-ready lifecycle,
  Keycloak's own image/config surface, MinIO's own storage layout) instead of re-implementing them.
- CNPG's declarative roles make "schema per service + per-service credentials" a first-class,
  auditable CR field rather than a hand-rolled init-container script.
- No new ingress controller, no new cert-manager dependency — smallest change that satisfies the
  AC, consistent with the issue's own EPIC-14 deferral.

**Negative / risks**

- Three new external chart-repo dependencies (`cloudnative-pg`, `codecentric`, `charts.min.io`) —
  CI now does `helm repo add` for the first time (`.github/workflows/helm-ci.yml`); each pinned
  version needs periodic bumping (a maintenance task, not tracked as a FOLLOWUPS item yet since
  there's no Dependabot-for-Helm equivalent wired up).
- The CNPG operator living outside the umbrella release is a deliberate asymmetry from "every
  subchart is declared in Chart.yaml" — documented here and in `infra/helm/beekeepingit/README.md`
  so it isn't mistaken for an oversight.
- Self-signed TLS means clients must trust-on-first-use (`-k`/`--insecure` or an explicit
  `--resolve` + cert pin for local testing) until EPIC-14 fronts it with a real CA.
- ~~The `keycloak`/`minio` wrapper charts' own vendored `.tgz` must be committed~~ — this was a
  real, confirmed bug (Flux's GitOps deploy sources the umbrella chart directly from Git, and its
  source-controller doesn't recursively resolve a subchart's own nested dependency, so it silently
  deployed nothing for Keycloak/MinIO). Fixed for good, not patched, in
  [ADR-0012](0012-keycloak-minio-standalone-helmreleases.md): Keycloak/MinIO no longer nest inside
  this umbrella chart at all.

## Alternatives considered

- **Hand-roll all four** (matching `smoke`'s original precedent). Rejected: re-implements
  Postgres HA/backup-ready lifecycle management, Keycloak's own startup/config surface, and MinIO's
  storage/bucket layout for no benefit at this stage — more code to maintain with none of the
  vendored charts' battle-testing.
- **Bitnami charts** for Postgres/Keycloak/MinIO. Considered and rejected: Bitnami's 2025 shift of
  most images/charts behind a paid "Secure Images" subscription (only a frozen, unmaintained
  "Legacy" tier stays free) makes it a poor long-term dependency for a project with no such
  subscription.
- **Plain StatefulSet + `postgis/postgis` image** for Postgres (no operator). Rejected in favor of
  CNPG: we'd hand-write the exact schema/role/credential provisioning CNPG already provides
  declaratively, and CNPG leaves an HA/backup upgrade path open later without a rewrite.
- **cert-manager** for gateway TLS. Deferred, not rejected — reasonable when EPIC-14 needs a real
  CA; unnecessary complexity for a self-signed dev/CI cert today.

## Follow-ups

- EPIC-14 (#15): production-grade IdP (Authentik) flow/RBAC hardening, trusted-CA TLS (cert-manager or
  equivalent), and secret-management hardening beyond the generated-Secret idiom used here.
- Live-cluster CI for the `postgres` subchart's `helm test` PostGIS smoke-query hook landed in
  `helm-e2e.yml` (`#154`): it now runs automatically on infra PRs, not only via a developer's local
  `beekeeping` k3d cluster. Equivalent liveness checks for the other three (authentik/minio/gateway)
  extend that same job once those subcharts grow their own `helm test` hooks. (Authentik's release
  now ships its own `helm test` ready-probe — ADR-0016.)
