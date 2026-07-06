# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## Tooling — deferred (post-#19)

- **Pinned-tool updates** — Dependabot covers GitHub Actions + Go modules (`gomod`, #88); add a
  mechanism (renovate/mise) to bump the `mise.toml` tool pins, which Dependabot can't. `flutter`
  landed pinned in `mise.toml` with `#21` — include it once such a mechanism exists.

## #21 — client/ follow-ups

- **Visual rendering verified after-the-fact, PWA install/offline QA still not done** — a
  manual pass (screenshot + DOM inspection of a built/served bundle) confirmed the home
  screen actually renders (title, subtitle, gateway status, themed button) and found/fixed
  a real bug (see below); a human should still `flutter run -d chrome` once to confirm the
  PWA installs and the service worker caches the app shell offline, before/soon after this
  merges.
- **Fixed: the app rendered blank without `--no-web-resources-cdn`** — `flutter build
web`/`flutter run` default to fetching CanvasKit/fonts from Google's CDN
  (`www.gstatic.com`) at runtime; wherever that CDN is unreachable, the Flutter engine never
  paints and the page is blank (only the bootstrap `<script>` tag in the DOM, no
  `flutter-view`/canvas). Fixed by always passing `--no-web-resources-cdn` in
  `task dart:build` (bundles CanvasKit/fonts locally instead) — genuinely required for an
  offline-first PWA, not just a workaround for this session's sandboxed network. Pass the
  same flag with `flutter run` for local dev (documented in `client/README.md`).
- **App icons are Flutter's default template icons** — `client/web/icons/*` and
  `favicon.png` are `flutter create`'s stock icon, not project artwork (none exists yet);
  swap for a real logo whenever the project gets a brand pass.
- **State management: Riverpod** — chosen and documented in
  [`client/README.md`](client/README.md) (AC: "a chosen state-management pattern is
  established and documented"). Revisit only if a concrete need pushes against it once real
  offline/PowerSync state lands (`#23`).

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
- **Why:** #86 (GitOps) and #88 (CI/CD) have both landed, but neither gives CI a **live cluster** —
  `helm-ci.yml` is still a dry-run and `build-publish.yml` publishes images for Flux to deploy, it
  doesn't run `helm test`. So this stays a manual/local step (or a future ephemeral-cluster CI job),
  independent of the now-closed #86/#88.
- **Where:** [`infra/helm/beekeepingit/charts/postgres/templates/tests/`](infra/helm/beekeepingit/charts/postgres/templates/tests/).
- **Status:** open (not blocked by #86/#88) — exercised manually against the local `beekeeping`
  k3d cluster (see `infra/README.md`); revisit if an ephemeral-cluster CI job is added.

## EPIC-13 (#88) — CI/CD pipeline: dormant-activation ledger

The path-filtered pipeline landed as a **ready-but-dormant framework** (no component is
container-buildable yet — see [ADR-0014](docs/adr/0014-cicd-pipeline.md)). Activate these as code
lands; none blocks #88's merge:

- **First service `Dockerfile`** — `build-publish.yml`'s `detect` job auto-picks up any directory
  with a `Dockerfile`; no workflow edit needed. This is when publish→scan→deploy is first exercised
  end-to-end. Also move per-component lint/test from the global `task ci` into the matrix via scoped
  targets (e.g. `task go:test -- <dir>`) when services add them.
- **Flux image-automation activation** (`infra/gitops/image-automation/`) — install the two extra
  controllers, provision the **Git write-credential** secret (an EPIC-14 #89 secrets task), copy the
  `example-service-image.yaml` per service, move the objects under a reconciled path, and add the
  `{"$imagepolicy": ...}` setter marker to the service's deploy manifest. Steps in that dir's README.
- **Trivy `config` → blocking** — flip `security-scan.yml`'s `trivy-config` job `exit-code` to `1`
  once #89 triages the pre-existing Helm/k8s misconfig baseline. Owned by #89.
- **Dependabot ecosystems** — add `docker` (per-service Dockerfiles) and `npm` (admin app) to
  `.github/dependabot.yml` as those packages land. `pub` (Flutter client) is done (`#21`).
- **macOS/iOS CI** — the disabled `ios-build` placeholder in `build-publish.yml` is enabled at
  **M5 by EPIC-15** (needs an Apple Developer account + macOS runners); do not enable before then.

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
  [ADR-0013](docs/adr/0013-observability-stack.md).
- **Status:** pending `#23`.

## EPIC-13 (#22) — PowerSync: real Sync Rules + connector + JWKS still owed to #23/#106

- **What:** `#22` lands the PowerSync subchart (self-hosted service + Postgres storage backend,
  D-6/ADR-0005) with two documented local-dev stopgaps: (1) `sync-config.yaml` is a placeholder
  (`streams.placeholder`, no real tables) because `apiaries`/`organizations` don't exist yet; (2)
  `client_auth.jwks_uri` points at Keycloak's own realm JWKS endpoint instead of a real
  per-org sync-token connector (accepts any token signed by that realm's keys, not a
  sync-scoped one).
- **Why:** `#23` (walking-skeleton, still open) is where the real domain tables land, and
  `#106`'s design (`docs/architecture/sync.md`, ADR-0006) is where the real org-scoped Sync
  Rules stream and the `/v1/sync/token` connector endpoint are meant to be built. `#22` only
  needs PowerSync running and healthy as part of the single bring-up command, not a working
  end-to-end sync round-trip — building the real thing now would duplicate `#23`/`#106`'s work
  ahead of the tables it depends on.
- **Where:** [`infra/helm/beekeepingit/charts/powersync/values.yaml`](infra/helm/beekeepingit/charts/powersync/values.yaml)
  (`syncConfig`, `auth.jwksUrl`).
- **Status:** pending `#23`/`#106`.

## #22 (before merge) — one clean end-to-end `dev-up.sh` reproducibility run still owed

Two full `dev-up.sh` runs from a torn-down cluster (below) already caught and fixed real bugs —
each individual piece (Postgres config, PowerSync, Keycloak, MinIO, teardown) has been directly
observed working live. What's still outstanding: a single, uninterrupted `dev-down.sh` →
`dev-up.sh` pass start-to-finish, to confirm the whole script (not just its parts) is reproducible
in one go. The last attempt was interrupted mid-run by the local `beekeeping` k3d cluster's own
container(s) restarting unprompted several times in the same session (see the
`k3d-docker-restart-flakiness` memory — concurrent sessions on the shared cluster, not this PR's
changes) — recovery via plain `up.sh` worked every time and lost no data, but never stayed up long
enough for one fully clean, uninterrupted timed run. Re-run `infra/cluster/dev-down.sh` then
`infra/cluster/dev-up.sh` once, ideally with no other session touching the `beekeeping` cluster
concurrently, before considering `#22` fully done.

**Status:** functionally verified piece-by-piece (see below); one clean end-to-end timing run
pending before merge.

Findings from the runs so far (not just `helm lint`/`template`):

- **PowerSync needs `POWERSYNC_CONFIG_PATH`.** The image doesn't infer its config location from
  the mounted volume — it looks for `/app/powersync.yaml` by default and exits fatally if that
  literal path is missing. Fixed by setting `POWERSYNC_CONFIG_PATH=/config/service.yaml` (confirmed
  against `powersync-ja/self-host-demo`'s reference `docker-compose` service).
- **The placeholder sync-config query needs a real table.** `SELECT 1 AS id WHERE false` fails
  PowerSync's sync-rules validator ("Must have a result column selecting from a table") — a
  literal projection with no `FROM` doesn't qualify, and neither does selecting a literal column
  from a table. Fixed by selecting an actual column (`schemaname`) from Postgres's always-present
  `pg_catalog.pg_tables`, still gated by `WHERE false` so it never returns/replicates a row.
- **`helm dependency build` must re-run after every local subchart edit.** `infra/helm/beekeepingit/charts/*.tgz`
  is a packaged snapshot Helm actually installs from (not the live `charts/<name>/` source
  directory) — editing a subchart's templates/values without rebuilding silently installs the
  stale snapshot. Not a bug in the shipped code, just a sharp edge worth calling out here since it
  cost real time to diagnose.
- **The documented "apply Keycloak/MinIO HelmReleases directly for local-only testing" step
  (previously in `infra/README.md`) never actually worked standalone.** Both files'
  `dependsOn: [beekeepingit]` targets the *HelmRelease object* named `beekeepingit`, which only
  exists once the cluster is GitOps-bootstrapped (`infra/gitops/clusters/dev/`) — bootstrapping
  that, though, makes Flux deploy the umbrella chart from `main`, defeating local branch testing.
  `dev-up.sh`/`dev-down.sh` (`#22`) fix this by stripping `dependsOn` at apply-time for this
  direct-install path only (committed files untouched) — the umbrella release's own `--wait`
  already guarantees the Secret/ConfigMap these referenced exist, which is all `dependsOn` was
  protecting in the first place.
- Confirmed end-to-end from an empty cluster: `wal_level=logical` + `powersync_storage` DB +
  `powersync` role (`Replication` attribute) + `powersync` publication (`puballtables=t`) all
  present; PowerSync pod reaches a clean steady state (replication slot active, storage
  connected, no JWKS-fetch errors); PostGIS `helm test` passes; Keycloak realm reachable through
  the gateway; MinIO health endpoint returns 200; the whole stack survived a k3d container
  restart (a known, unrelated flakiness — see the `k3d-docker-restart-flakiness` memory) with no
  data loss, recovered by `up.sh` alone.

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
