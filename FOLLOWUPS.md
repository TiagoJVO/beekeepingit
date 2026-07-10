# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## Branch `claude/distracted-mendel-473cac` — milestone/stream regroom (2026-07-11)

Flat **M0–M5** re-sliced into a per-feature incremental ladder + cross-cutting streams (**D-14**),
applied directly to GitHub Issues/Milestones. Pre-change backup lives at
`scratchpad/backlog-backup-2026-07-11/` (with `RESTORE.md`).

- **Done (live on GitHub):** removed backward dep `#16◂#9` + epic-level offline gates
  (`#3/#13/#16 ◂ #7`), repointed `#31◂#55`; unpinned stream epics `#7 #8 #12 #15 #16` (+`stream`
  label); created `M2 · Apiaries` … `M11 · iOS & on-device AI`, renamed `M0`/`M1`, deleted empty old
  `M2–M5`, moved ~55 open issues.
- **Scope gates (settle before sizing a feature's stories):** `Q-MAP`/`Q-DIST`/`Q-SEARCH` → M2 (do
  first), `Q-JOUR` → M4, `Q-TODO` → M5, `Q-IMP` → M6, `Q-AICLOUD` → M8, `Q-NOTIF` → M9. Resolve via
  the `requirements-folder` skill (answer → `D-*`/`FR-*`, then delete the `Q-*`).
- **Provisional placements:** stream stories `#56–62` and `#165` → M2, and `#90`/`#92` → M6, by
  "first need"; revisit if a thinner M2 (the declined vertical-slice option) is wanted later.
- **Housekeeping:** re-check any Project board views that filtered the now-deleted `M2–M5`; sync the
  new `stream` label if a label-sync tool is used.

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
