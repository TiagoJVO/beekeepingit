# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## #84 (ADR-0012) — pin `releaseName` on the umbrella `HelmRelease`

- **What:** `infra/gitops/apps/dev/beekeepingit-helmrelease.yaml` doesn't set `spec.releaseName`,
  so Flux's helm-controller defaults it to `<targetNamespace>-<HelmRelease name>` —
  `beekeepingit-dev-beekeepingit` in practice (confirmed on the live cluster), not
  `beekeepingit`. The new `keycloak`/`minio` `HelmRelease`s hardcode references to that actual
  name (`beekeepingit-dev-beekeepingit-keycloak-admin-credentials`, etc.).
- **Why it matters:** if this ever changes (releaseName pinned, targetNamespace altered), those
  hardcoded references go stale silently. Pinning `spec.releaseName: beekeepingit` there would
  make the name match direct `helm install beekeepingit` too — but the release is already live
  under the auto-generated name, so renaming it needs a deliberate migration (old release
  cleanup), not a drive-by edit.
- **Where:** `infra/gitops/apps/dev/beekeepingit-helmrelease.yaml`,
  [`docs/adr/0012-keycloak-minio-standalone-helmreleases.md`](docs/adr/0012-keycloak-minio-standalone-helmreleases.md)
  Follow-ups.
- **Status:** not blocking; revisit deliberately, not as a side effect of another change.

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
