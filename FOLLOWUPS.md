# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## #85 → #20 — reuse `services/shared/dbaccess`, don't re-derive

- **What:** `#85` landed `services/shared/dbaccess` (pgx + sqlc + goose, `Connect`/`Migrate`)
  and `services/shared/objectstore` (S3-compatible adapter) as a library, deliberately
  scoped to stop short of a config-loading framework.
- **Why it matters:** `#20` ("Shared Go service template") also lists "a Postgres data-access
  layer (pgx + sqlc, goose/golang-migrate)... demonstrated by at least one sample endpoint" as
  an acceptance criterion. When #20 is picked up, import `services/shared/dbaccess` (and
  `objectstore` if the sample endpoint needs uploads) instead of re-implementing the same
  pgx/sqlc/goose wiring — and add the `go.work` (or `replace` directive) needed to link the
  two modules, since #85 didn't need one with only a single module in the repo.
- **Where:** [`services/shared/README.md`](services/shared/README.md),
  [`docs/adr/0011-infra-abstraction-object-storage-db-access.md`](docs/adr/0011-infra-abstraction-object-storage-db-access.md).
- **Status:** pending #20.

## Tooling — deferred (post-#19)

- **Add `flutter`/`dart` to [`mise.toml`](mise.toml)** when the Flutter client package lands (D-10);
  wire `dart:build` and have the client `include:` the shared `analysis_options.yaml` +
  `flutter_lints`.
- **Pinned-tool updates** — Dependabot covers GitHub Actions only; add a mechanism (renovate/mise)
  to bump `mise.toml` pins.

## EPIC-13 (platform) — wire API-contract tooling into CI

- **What:** OpenAPI **lint** (Redocly/Spectral), a **breaking-change diff** (`oasdiff`) gate on
  PRs, **server-stub + typed-client codegen** (Go `oapi-codegen`; Dart/TS clients), and
  **contract tests** at service boundaries.
- **Why:** contract-first only holds if CI enforces spec↔code parity and blocks silent `/v1`
  breaks (ADR-0003 / NFR-TST-1). Until then the specs are hand-linted locally.
- **Where:** [`contracts/openapi/`](contracts/openapi/) · design:
  [`docs/architecture/api-contracts.md`](docs/architecture/api-contracts.md) §11 ·
  ADR: [`docs/adr/0003-api-contract-conventions.md`](docs/adr/0003-api-contract-conventions.md)
- **Status:** pending EPIC-13 (#83/#84). Not a blocker for #108 (design/skeletons only).

## EPIC-13 (#83/#84) — `helm test` smoke hooks need a live cluster

- **What:** the `postgres` subchart's PostGIS smoke-query `helm test` hook (and any future
  liveness checks for `keycloak`/`minio`/`gateway`) only run against a real cluster
  (`helm test beekeepingit -n beekeepingit-dev`), not in CI — `.github/workflows/helm-ci.yml` is a
  `helm lint`/`helm template` dry-run with no live cluster.
- **Why:** deploying to a live cluster from CI is `#86` (GitOps)/`#88` (CI/CD pipeline), still
  pending — same limitation `docs/architecture/platform.md` already notes for the whole chart.
- **Where:** [`infra/helm/beekeepingit/charts/postgres/templates/tests/`](infra/helm/beekeepingit/charts/postgres/templates/tests/).
- **Status:** pending #86/#88 — until then, exercised manually against the local `beekeeping`
  k3d cluster (see `infra/README.md`).

## EPIC-13 (#87) — Loki/Tempo: swap filesystem/local-disk storage for MinIO-backed

- **What:** reconfigure `loki` (`loki.storage.type`) and `tempo`
  (`tempo.tempo.storage.trace.backend`) in
  [`infra/helm/beekeepingit/values.yaml`](infra/helm/beekeepingit/values.yaml) to use MinIO
  (S3-compatible) instead of the current filesystem/local-disk storage.
- **Why:** `#87` landed before `#84`, so there was no object store yet to point at —
  filesystem/local-disk storage is the documented interim state (see
  [`docs/architecture/platform.md#observability`](docs/architecture/platform.md#observability),
  [ADR-0008](docs/adr/0008-observability-stack.md)).
- **Where:** `infra/helm/beekeepingit/values.yaml` (`loki:`/`tempo:` blocks), MinIO credentials
  from the `minio` subchart's generated Secret (`#84`).
- **Status:** now actionable — `#84` merged MinIO to `main`. Not done in the same change that
  resolved this conflict; do it as its own follow-up commit/PR.

## EPIC-13 (#87) — verify real walking-skeleton telemetry once #23 lands

- **What:** once `#23`'s Go service ships and its OTel SDK is wired to
  `otel-collector:4317` (in-cluster OTLP endpoint), re-run the
  [`infra/observability-smoke-test.sh`](infra/observability-smoke-test.sh) checks against
  its real traffic instead of the `telemetrygen` stand-in, and confirm its traces/logs
  show up correlated in Grafana.
- **Why:** `#87`'s AC "the walking-skeleton slice shows its traces and logs in this stack"
  can't be literally satisfied until a real service emits telemetry — `#23` was still
  pending when `#87` landed. The `telemetrygen` script proves the pipeline works now; this
  item closes the AC for real.
- **Where:** [`docs/architecture/platform.md#observability`](docs/architecture/platform.md#observability),
  [ADR-0008](docs/adr/0008-observability-stack.md).
- **Status:** pending `#23`.

## #84 — verified live against the local `beekeeping` k3d cluster (2026-07-04)

Full `helm install`/`helm test` verification from WSL2 caught and fixed two real bugs before
merge (not just `helm lint`/`template`, which don't exercise a live cluster):

- **Gateway backend Service name was wrong.** `charts/gateway/values.yaml`'s
  `backend.serviceName` guessed `beekeepingit-keycloakx`; the vendored `keycloakx` chart actually
  creates `beekeepingit-keycloakx-headless` (StatefulSet DNS) and `beekeepingit-keycloakx-http`
  (the one that serves traffic) — confirmed via a live render and fixed.
- **Schema grants failed at bootstrap.** `postInitApplicationSQL` (cluster.yaml) ran the
  per-service `GRANT ... TO <schema>_svc` before `spec.managed.roles` had created those roles
  (bootstrap runs before role reconciliation), so every install failed with `role "identity_svc"
does not exist`. Fixed by only creating schemas (owned by the `beekeepingit` app user) at
  bootstrap, and moving the grants to a new `templates/schema-grants-job.yaml` post-install hook
  that retries until each role exists.
- Confirmed end-to-end: Postgres cluster healthy + `helm test` PostGIS smoke query passed +
  `identity_svc` could create a table in its own schema; Keycloak realm `beekeepingit` reachable
  through the gateway's TLS Ingress (`/.well-known/openid-configuration` served correctly); MinIO
  health endpoint returned 200.
