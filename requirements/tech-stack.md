# Technology Stack — _intended direction_

> **Intention, not a rule.** This is the stack we currently intend to use; like the rest of
> `requirements/`, it can be questioned and changed (with the user). The M0/M1/M2 walking
> skeleton has since implemented most of it — `docs/` (esp. [docs/CODEMAPS/](../docs/CODEMAPS/)
> and `docs/architecture/`) documents the stack as actually built; this file stays the
> intent record and isn't rewritten to track build status. The decisions behind it are logged
> in [decisions.md](decisions.md) (`D-5`…`D-10`) and are revisitable. The "Status: Decided"
> notes below mean a decision was recorded — not that anything is built.

The reasoning behind the intended stack, and the input to a future service decomposition.

## Summary

| Layer                 | Choice                                                                                | Status                                      |
| --------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------- |
| Client                | **Flutter (Dart)** — Web/PWA first, native later                                      | Decided (D-5, D-10)                         |
| Backend microservices | **Go**                                                                                | Decided (D-5)                               |
| Admin web app         | **React + TypeScript**                                                                | Decided (D-5)                               |
| Primary database      | **PostgreSQL + PostGIS**                                                              | Decided (D-6)                               |
| On-device store       | **SQLite**                                                                            | Decided (D-6)                               |
| Offline sync engine   | **PowerSync** (self-hosted, Open Edition)                                             | Decided (SP-1 → D-6)                        |
| Identity / auth       | **Authentik (self-hosted, OIDC)** — provider-agnostic OIDC boundary                   | Decided (D-7, ADR-0016)                     |
| AI assistant          | **NL→query & proposed actions; cloud model first (e.g. Claude API), on-device later** | Decided (D-8, D-11)                         |
| API style             | REST + OpenAPI (client); gRPC optional (inter-service)                                | Implemented (`contracts/openapi/`)          |
| Orchestration         | Kubernetes + Helm                                                                     | Decided (NFR-ARC)                           |
| Observability         | OpenTelemetry + Prometheus + Grafana + Loki/Tempo                                     | Implemented (ADR-0013)                      |
| Object storage        | MinIO (S3-compatible)                                                                 | Implemented (`services/shared/objectstore`) |
| CI/CD                 | GitHub Actions                                                                        | Implemented (`.github/workflows/`)          |
| Repo                  | Monorepo                                                                              | Decided (D-9)                               |
| Platform rollout      | PWA → Android → iOS (native only when needed)                                         | Decided (D-10)                              |

> **Versions are intentionally unpinned here.** Pin them in each app/service manifest
> when scaffolded.

## The central reconciliation: offline-first ⨉ microservices

Offline sync wants a _consolidated, replicable_ store; microservices want
_per-service_ stores. For a single-org v1:

- All services run on **one PostgreSQL cluster**, each owning a **separate schema**
  (clean boundaries, no cross-schema writes).
- The **sync engine replicates only the client-relevant slice** to each device's
  SQLite, scoped by organization (and by user for activity ownership).
- Splitting schemas into independent databases later is a migration, not a rewrite.

Conflict policy (default): **server-authoritative, record-level last-write-wins**
with a conflict log; revisit field-level merge only where it hurts (`Q-SYNC`).

## Client — Flutter (Web/PWA first)

**Rollout (D-10):** ship **Flutter Web as an installable PWA** first, then native
**Android**, then **iOS** — native targets added only when a feature needs them. One
codebase throughout.

- **PWA shell:** web app manifest + service worker for installability and offline
  app-shell caching; "add to home screen" on Android/desktop (iOS later, with
  caveats).
- **Local data + sync:** **PowerSync** (self-hosted) — its **web SDK** in the PWA phase
  (wa-sqlite over OPFS/IndexedDB); **SQLite** on device in the native phase. Engine resolved by
  **SP-1** ([ADR-0005](../docs/adr/0005-sync-engine-choice.md)); web/PWA persistence validated.
- **Maps:** `flutter_map` + MapLibre/OSM tiles (open licensing; Mapbox alternative);
  works on web and native. Drives map view, location, proximity, distance
  (`FR-AP-2/3/5`).
- **Auth:** OIDC via **discovery** against the configured issuer (Authentik in v1) — the
  provider is a swappable detail, endpoints are read from `.well-known` (`openid_client`
  core on web; `flutter_appauth` on native). Offline login is a **native-phase** concern.
- **AI:** **cloud, online-only** in the PWA phase (calls the backend AI service — see
  below); on-device LLM arrives with native.
- **i18n / a11y:** Flutter `intl` (EN + PT, `NFR-I18N`); large-tap-target,
  screen-reader-friendly, gloves-friendly field UX (`FR-UX`, `FR-AX`, **WCAG 2.2 AA**).
- **Distribution:** hosted PWA now → Android **direct APK** (free) or Play ($25 once)
  → iOS native (Apple Developer **$99/yr** + macOS builds) when warranted.

## Backend — Go microservices

- **HTTP:** `chi` or `echo`; **Postgres:** `pgx` + `sqlc` (typed queries);
  **migrations:** `goose`/`golang-migrate`.
- **AuthN:** validate OIDC JWTs via JWKS (`coreos/go-oidc`) — **issuer-agnostic**,
  discovery-driven; **authZ:** org-scoped checks in a shared middleware.
- **Observability:** OpenTelemetry Go SDK (traces/metrics/logs) → OTel Collector.
- **Contracts:** OpenAPI per service (client-facing); gRPC optional inter-service.
- **Cross-cutting:** shared libs for audit/history (`FR-HIS`), tenancy context,
  error format, and the sync-publication contract.

## Admin web app — React + TypeScript

- **Build:** Vite (or Next.js if SSR is wanted later).
- **Speed-up options:** Refine or React-Admin for CRUD scaffolding, or shadcn/ui +
  TanStack Query/Table for full control.
- **Auth:** `react-oidc-context` (generic OIDC, discovery-driven). Online-only, no offline (`NFR-ROL-2`).
- Scope: org/member management, roles & permissions, (later) quotas/rate limits.

## Data — PostgreSQL + PostGIS

- **Geo:** PostGIS for proximity ordering and distance (`FR-AP-2/5`).
- **Flexible activity attributes:** typed `activities` table + **JSONB** attribute
  bag per activity type (`FR-AC-1`), with validation in the service.
- **Audit/history:** append-only history per entity with actor + timestamp
  (`FR-HIS`); must survive offline edits + sync.
- **Tenancy:** every owned row carries `organization_id`; enforce in queries +
  optionally Postgres RLS.

## Identity — Authentik (behind a provider-agnostic OIDC boundary)

- Self-hosted on k8s (its own bundled Postgres); an **application + OAuth2 provider** for the
  platform, provisioned declaratively via **blueprints**; ready for social/SSO later. The app
  depends only on **standard OIDC** (discovery + JWKS + standard claims) — the IdP is swappable
  (`ADR-0016`, [`docs/architecture/oidc-integration.md`](../docs/architecture/oidc-integration.md)).
- **Offline login:** cache access/refresh tokens + JWKS on device; validate locally
  within a grace window; require periodic online re-auth.
- **Org authorization:** the IdP handles authN only; **roles `admin`/`user` and org membership &
  resource ownership** are **app-side** (`organizations.memberships`, FR-TEN), never IdP roles;
  consider OpenFGA/Keto if fine-grained sharing grows.

## AI assistant — NL→query & actions (cloud first, on-device later)

- **Approach:** translate the request into a **structured query or action (tool call)**
  over the org's data — reads (accurate for "total honey last year", "overdue todos") and
  **proposed writes** ("set apiary X to 12 hives", user-confirmed); optional RAG for
  open-ended beekeeping Q&A later. Same pattern in both phases.
- **PWA phase — cloud, server-side:** a Go **AI service** receives the question, calls
  a **hosted LLM (e.g. Claude API)** to produce the structured query, runs it against
  Postgres (scoped), and returns the answer. Keys stay server-side; **online-only**.
- **Native phase — on-device:** same flow with a **local LLM** (`flutter_gemma` /
  llama.cpp; candidates Gemma 2 2B / Llama 3.2 3B / Phi-3.5-mini) + the local/cloud
  toggle (`NFR-AI-3`). Feasibility via **SP-2**.
- **Context scoping & write-safety:** organization (default) / apiary / journey
  (`FR-AI-1`); reads are parameterized and never reach beyond the selected scope. The
  `ai` service holds **no direct write access** — it **proposes** actions that the user
  **confirms** and the **owning service executes** via its normal API (`FR-AI-2`,
  `NFR-AI-4`, D-11).
- **Privacy / GDPR:** cloud mode sends org data to an external processor → needs
  **consent + DPA + no-training terms + EU-residency** consideration (`NFR-AI-1`,
  `NFR-CMP`, Q-AICLOUD).

## Infrastructure

- **k8s + Helm** (one cluster for v1, `NFR-ARC-3`); **GitOps: Flux** (`D-13`), hand-wired
  `Kustomization`/`HelmRelease` objects (not `flux bootstrap`), no ArgoCD.
- **Gateway/ingress:** **Traefik** (settled by `#84`/[ADR-0010](../docs/adr/0010-platform-backing-services-provisioning.md)
  — k3d already bundles it as the cluster's ingress controller, so it's reused rather than
  installing NGINX as a second one) (+ a thin BFF if needed).
- **Observability:** OpenTelemetry → Prometheus (metrics), Loki (logs), Tempo
  (traces), Grafana (dashboards) (`NFR-OBS`).
- **Object storage:** MinIO now (S3-compatible) → swap to cloud later (`NFR-ARC-2`).
- **CI/CD:** GitHub Actions (build/test/scan/publish images, deploy via Helm).

## Cross-cutting requirements honored here

- **GDPR** (`NFR-CMP`): EU-resident self-hosted data; export/erasure paths; explicit
  consent before any future cloud AI.
- **Testability** (`NFR-TST`): Go unit/integration (testcontainers), Flutter widget/
  integration tests, contract tests on OpenAPI, e2e on critical flows.
- **Maintainability** (`NFR-MNT`): monorepo, shared libs, consistent service template.

## Open spikes

- **SP-1** — ✅ **resolved → PowerSync** (self-hosted Open Edition), via a head-to-head +
  a working k8s prototype (create → offline edit → sync + LWW/conflict-log). See
  [ADR-0005](../docs/adr/0005-sync-engine-choice.md) /
  [SP-1 report](../docs/spikes/sp-1-powersync-vs-electricsql.md).
- **SP-2** _(native phase)_ — On-device LLM feasibility & NL→query accuracy on a
  mid-range phone. Not PWA-blocking.
