# EPIC-00 — Foundations & Walking Skeleton

- **Milestone:** M0
- **Phase:** PWA
- **Labels:** type/epic, area/infra
- **Requirements:** NFR-MNT-1, NFR-TST-1, NFR-ARC-1, NFR-ARC-2, NFR-ARC-3, NFR-OBS-1
- **Depends on:** EPIC-13
- **Spikes:** SP-1 (sync engine; owned by EPIC-06, consumed by the walking skeleton)
- **Summary:** Establish the monorepo tooling, the shared Go service template, the Flutter PWA app skeleton, and a local dev environment, then prove the architecture end-to-end with a single thin vertical slice (login → create → offline edit → sync).

## Stories

### Task Monorepo tooling & conventions (lint/format, task runner, pre-commit)
- **Labels:** type/task, area/infra, priority/high
- **Requirements:** NFR-MNT-1, NFR-TST-1
- **Milestone:** M0
- **Depends on:** EPIC-13
- **Acceptance criteria:**
  - [ ] Monorepo tooling and conventions are established and documented (per D-9); directories are created as work needs them, not pre-scaffolded.
  - [ ] Linters/formatters are configured per language (Go: gofmt/golangci-lint; Dart: dart format/analyze; TS: eslint/prettier) and runnable with a single task command.
  - [ ] A task runner (e.g. Makefile/Taskfile) exposes consistent `lint`, `format`, `test`, `build` targets across all packages.
  - [ ] Pre-commit hooks run format + lint on staged files and block commits that fail.
  - [ ] A new contributor can run one documented bootstrap command to install all required toolchains/dependencies.
- **Notes:** Aligns with D-9 (monorepo) and the monorepo path-filtered CI in EPIC-13.

### Task Shared Go service template (health, config, structured logging, OTel, JWT middleware, error format, DB access)
- **Labels:** type/task, area/infra, area/observability, priority/high
- **Requirements:** NFR-MNT-1, NFR-ARC-1, NFR-ARC-2, NFR-OBS-1
- **Milestone:** M0
- **Depends on:** EPIC-13
- **Acceptance criteria:**
  - [ ] A reusable Go service template exposes `/healthz` and `/readyz` endpoints returning correct status under healthy/unhealthy conditions.
  - [ ] Configuration is loaded from environment/config with sane defaults and fails fast on missing required values.
  - [ ] Structured (JSON) logging is wired with request-scoped fields and correlated to traces.
  - [ ] OpenTelemetry traces, metrics, and logs are emitted to the OTel collector (consistent with EPIC-13 observability stack).
  - [ ] JWT validation middleware verifies Keycloak tokens via JWKS and rejects invalid/expired tokens with the standard error format.
  - [ ] A consistent error-response format and a Postgres data-access layer (pgx + sqlc, goose/golang-migrate) are provided and demonstrated by at least one sample endpoint.
- **Notes:** Stack per D-5/D-6/D-7 and tech-stack.md (Go backend section). Auth integration depends on Keycloak from EPIC-01/EPIC-13; full org-scoped authZ middleware is built in EPIC-01.

### Task Flutter app skeleton (PWA shell, routing, theming, state mgmt, i18n scaffold)
- **Labels:** type/task, area/infra, area/i18n-a11y, priority/high
- **Requirements:** NFR-MNT-1, NFR-ARC-2
- **Milestone:** M0
- **Depends on:** EPIC-13
- **Acceptance criteria:**
  - [ ] A Flutter app builds and runs as an installable PWA (web app manifest + service worker for app-shell caching).
  - [ ] App-level routing/navigation is in place with at least a placeholder home and detail route.
  - [ ] A theming approach (light/dark or brand theme) and a chosen state-management pattern are established and documented.
  - [ ] An i18n scaffold (Flutter `intl`) is wired with EN as default and PT stub, so strings are externalized from the start.
  - [ ] The skeleton runs against the local dev environment and can call a backend endpoint through the gateway.
- **Notes:** PWA-first per D-10; i18n/a11y depth is owned by EPIC-11, this story only scaffolds. State-mgmt choice may reference Flutter conventions in tech-stack.md.

### Task Local dev environment (Postgres+PostGIS, Keycloak, sync engine, MinIO, gateway)
- **Labels:** type/task, area/infra, priority/high
- **Requirements:** NFR-ARC-2, NFR-ARC-3
- **Milestone:** M0
- **Depends on:** EPIC-13
- **Acceptance criteria:**
  - [ ] A single documented command (e.g. docker-compose or local k8s) brings up Postgres+PostGIS, Keycloak, the chosen sync engine, MinIO, and the gateway/ingress.
  - [ ] PostGIS is enabled and a smoke query confirms the spatial extension is available.
  - [ ] Keycloak starts with a seeded realm/client usable by the app and services for local login.
  - [ ] MinIO is reachable via an S3-compatible client and the gateway routes to at least one backend service.
  - [ ] Teardown/reset is documented and leaves no orphaned state, so the environment is reproducible.
- **Notes:** Mirrors the deployed stack from EPIC-13 (NFR-ARC-3, single cluster). Sync engine identity is pending SP-1 (EPIC-06); use the spike's chosen/candidate engine.

### Task Walking-skeleton vertical slice: login → create trivial record → offline edit → sync
- **Labels:** type/task, area/offline-sync, area/auth-identity, priority/critical
- **Requirements:** NFR-ARC-1, NFR-ARC-3, NFR-OBS-1, NFR-TST-1
- **Milestone:** M0
- **Depends on:** EPIC-00 (template, skeleton, local env), EPIC-06 (SP-1 sync engine), EPIC-13 (deploy + observability)
- **Acceptance criteria:**
  - [ ] A user can log in via Keycloak (OIDC) from the Flutter PWA.
  - [ ] The user can create a trivial record that is persisted through a Go service into Postgres.
  - [ ] The record can be edited while offline and the change is queued locally (web SDK persistence).
  - [ ] When connectivity returns, the queued change syncs to the server and is reflected on reload.
  - [ ] The full slice is deployed to the cluster via CI/CD and its traces/logs are visible in the observability stack (satisfies the M0 exit criteria).
  - [ ] An automated test (integration or e2e) exercises the create → edit → sync path.
- **Notes:** This is the M0 exit-criteria slice. Offline behavior: edits made offline are stored locally and applied server-side on reconnect (server-authoritative last-write-wins per Q-SYNC / tech-stack.md). Sync engine choice via SP-1. History (FR-HIS-1) is intentionally out of scope for this foundations slice.
