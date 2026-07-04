# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## #84/#86 — verify Flux resolves the new vendored subchart dependencies

- **What:** `#84` added `keycloak`/`minio` as wrapper charts around vendored dependencies
  (`codecentric/keycloakx`, the official `charts.min.io` chart) — resolved via `helm dependency
build`, never committed (`.gitignore`: `**/charts/*.tgz`). `#86`'s `HelmRelease` points Flux's
  `helm-controller` at this chart directly from the Git source (`chart: ./infra/helm/beekeepingit`),
  not a pre-packaged release.
- **Why it matters:** unconfirmed whether `helm-controller` resolves remote chart-repo
  dependencies (`helm repo add` + `dependency build` equivalent) at reconcile time the way local
  `helm install`/CI's `helm-ci.yml` do explicitly, or expects them vendored/committed. If not,
  Flux's first reconcile of this chart after both PRs land could fail.
- **Where:** [`infra/gitops/apps/dev/beekeepingit-helmrelease.yaml`](infra/gitops/apps/dev/beekeepingit-helmrelease.yaml),
  [`infra/helm/beekeepingit/Chart.yaml`](infra/helm/beekeepingit/Chart.yaml).
- **Status:** verify on the next `dev` reconcile after both land; not blocking either PR
  individually (each was independently live-verified via direct `helm install`, not via Flux).

## Tooling — deferred (post-#19)

- **golangci-lint v1 → v2** config migration (v2 is current; `.golangci.yml` uses v1 schema).
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
