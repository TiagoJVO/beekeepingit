# Platform: single k8s cluster + Helm umbrella chart

> **Status:** As-built (EPIC-13 #83, #87). Intent: `NFR-ARC-1` (microservices, clear APIs),
> `NFR-ARC-3` (single cluster for v1, design for future scaling without forcing it),
> `NFR-OBS-1`/`NFR-PER-1` (observability), `D-1` (full microservices, still one
> cluster). Tech choice: [`requirements/tech-stack.md`](../../requirements/tech-stack.md)
> (`k8s + Helm`; `OpenTelemetry + Prometheus + Grafana + Loki/Tempo`).

## Cluster

Local, single-node **k3d** cluster named `beekeeping` (bundles Traefik as the ingress
controller/load balancer). Chosen because it runs identically on a developer's WSL2/Docker
machine and on a GitHub-hosted Ubuntu runner (Docker-in-Docker) — no retooling needed when CI
starts deploying to a live cluster (`#86`/`#88`).

- Config: [`infra/cluster/k3d-config.yaml`](../../infra/cluster/k3d-config.yaml) — 1 server, 0
  agents, host ports `8080:80` / `8443:443` mapped to the load balancer.
- Bring-up: [`infra/cluster/up.sh`](../../infra/cluster/up.sh) — idempotent (creates the cluster
  if absent, otherwise starts it).
- Teardown: [`infra/cluster/down.sh`](../../infra/cluster/down.sh) — deletes the cluster and
  flags any orphaned k3d docker volumes.

Postgres+PostGIS, the OIDC IdP, MinIO and the gateway landed with `#84` (see below); the IdP was
**Keycloak** at `#84` and was later **replaced by Authentik** (D-7 revised,
[ADR-0016](../adr/0016-replace-keycloak-with-authentik.md)). PowerSync's
_infra_ (self-hosted service + Postgres storage backend, D-6/ADR-0005) landed with `#22`, with a
placeholder sync-config and an IdP-JWKS stopgap since no domain tables/connector exist yet
(see `FOLLOWUPS.md`). The walking-skeleton Go services, the PWA, and PowerSync's real org-scoped
Sync Rules + connector land with `#23`/`#106`. All deploy through the umbrella chart below rather
than standing up their own release.

One thing doesn't: the **CloudNativePG operator** (below) is cluster-scoped, so — like Traefik —
it's installed once by `up.sh` itself rather than through the umbrella chart.

- **CloudNativePG operator**: `up.sh` also does `helm repo add cnpg
https://cloudnative-pg.github.io/charts` + `helm upgrade --install cnpg-operator
cnpg/cloudnative-pg -n cnpg-system --create-namespace`, right after cluster bring-up. It's a
  prerequisite for the umbrella chart's `postgres` subchart (its `Cluster` custom resource), not a
  subchart itself — installing/upgrading it on every per-environment `helm upgrade beekeepingit`
  would be wrong for something meant to serve every environment on the cluster (see
  [ADR-0010](../adr/0010-platform-backing-services-provisioning.md)). `down.sh` needs no change:
  deleting the k3d cluster removes it along with everything else.

## Helm umbrella chart

[`infra/helm/beekeepingit/`](../../infra/helm/beekeepingit/) is one Helm chart that composes
every service as a **subchart** under `charts/`, so the whole platform deploys/upgrades as one
release. Conventions (namespace, resource tiers, values schema, how a service subchart plugs in)
are documented in the chart's own [README](../../infra/helm/beekeepingit/README.md) — this
section covers the _why_.

- **Namespace**: one per environment (`beekeepingit-<env>`), created at install time via
  `--create-namespace` rather than a chart-managed `Namespace` resource, so `helm uninstall`
  never risks deleting a namespace holding anything else.
- **Resource sizing**: three presets (`small`/`medium`/`large`, requests+limits) in
  `global.resources`, so every subchart sizes itself from one place per environment instead of
  hardcoding CPU/memory — this is what "resource requests/limits are defined for each
  component" means before any component exists yet.
- **Values schema** (`values.schema.json`): validates `global.environment`
  (`dev`/`staging`/`prod`), `global.namespace`, and the resource-tier shape, enforced by
  `helm lint`/`helm template`/`helm install`.
- **Per-environment overrides**: `environments/{dev,staging,prod}.yaml` overlay `global.*` (`-f`
  on top of `values.yaml`). Only `dev` is deployed anywhere today; `staging`/`prod` exist to
  prove the override mechanism per `NFR-ARC-2` (don't force cloud/multi-env now, but don't block
  it later either).
- **Vendored vs hand-rolled subcharts** (`#84`, [ADR-0010](../adr/0010-platform-backing-services-provisioning.md)):
  `postgres` (a CloudNativePG `Cluster` CR + per-service credential Secrets) and `gateway` (a
  portable `Ingress` + self-signed TLS Secret, reusing k3d's Traefik) are hand-rolled — there's
  nothing to vendor for either. `authentik` and `minio` only hold what a vendored chart can't own
  itself (generated config/credential Secrets; for the IdP, also the declarative **blueprint**
  ConfigMap — the analogue of a realm import) — the actual vendored charts (the `authentik` chart
  from `charts.goauthentik.io`, the official `charts.min.io` MinIO chart) run as their own
  standalone Flux `HelmRelease`s (`infra/gitops/apps/dev/`), not nested here, since Flux's
  GitRepository-sourced charts don't recursively resolve a subchart's own vendored dependency (the
  original nested-wrapper approach silently deployed zero of the vendored chart's workload) — see
  [ADR-0012](../adr/0012-keycloak-minio-standalone-helmreleases.md) (which set this standalone
  pattern for the then-Keycloak IdP + MinIO and supersedes the wrapper-chart part of ADR-0010) and
  [ADR-0016](../adr/0016-replace-keycloak-with-authentik.md) (which swapped that IdP to Authentik,
  same pattern).
- `powersync` (`#22`, D-6/[ADR-0005](../adr/0005-sync-engine-choice.md)) is hand-rolled too —
  PowerSync's self-hosted Open Edition ships as a bare Docker image, not a Helm chart, and its
  bucket-storage backend is Postgres (not MongoDB, PowerSync's historical default), matching the
  SP-1 spike's proven config and avoiding a second datastore technology.
- The former `charts/smoke/` placeholder (proved the umbrella→subchart wiring before any real
  service existed) was removed once `#84`/`#87` added the first real subcharts.
- `networkpolicy` (EPIC-14 `#89`, `NFR-SEC-1`) is hand-rolled and holds no workload — just
  `NetworkPolicy` objects (`networking.k8s.io/v1`, a namespace-scoped core API resource, not tied
  to a Helm release). A **default-deny** baseline (all ingress + egress) plus one
  **explicit-allow pair per real traffic edge**, generated from a single `values.yaml` edge list
  (`.Values.edges`) rather than hand-duplicated YAML per flow — each edge renders both an egress
  rule (on the caller) and an ingress rule (on the target), since default-deny blocks both
  directions independently, and ports are **container** ports (netpol matches after Service
  DNAT — e.g. Authentik's Service listens on 80 but its rules must say 9000). Edges cover
  gateway→backends, service→service (from `charts/services/values.yaml`'s `INTERNAL_*_URL`
  wiring), service→Postgres, powersync→Postgres, CNPG's own operational plumbing (instance→API
  server, operator→instance status port — without which the `Cluster` never reconciles), and
  Authentik's own internal topology (server/worker/bundled Postgres) — the last because
  Authentik's Deployments live in the **same namespace** (its own standalone Flux `HelmRelease`,
  ADR-0012) and are therefore governed by this chart's default-deny too, even though this chart
  doesn't own their pods. **These policies are enforced on k3d/k3s**: k3s embeds kube-router's
  network-policy controller, so NetworkPolicy is live even though the CNI itself is Flannel
  (which has no netpol support of its own — an easy wrong assumption, made and corrected in
  PR #224's first CI round). Two same-namespace releases are deliberately **excluded** from the
  default-deny selector for now — the **observability stack** and **MinIO** — because their
  internal flows span four vendored third-party charts whose pod labels/ports need live-cluster
  verification before they can be enumerated as edges; tracked on `#89`.

## Observability

Stack per `requirements/tech-stack.md`: **OpenTelemetry Collector → Prometheus (metrics) /
Loki (logs) / Tempo (traces) → Grafana**, satisfying `NFR-OBS-1` (logging, monitoring,
alerting) and contributing to `NFR-PER-1`.

It is **its own chart** ([`infra/helm/observability/`](../../infra/helm/observability/)) +
**its own Flux `HelmRelease`**
([`infra/gitops/apps/dev/observability-helmrelease.yaml`](../../infra/gitops/apps/dev/observability-helmrelease.yaml),
`dependsOn: [beekeepingit, minio]`), **not part of the beekeepingit umbrella** — its
Loki/Tempo need MinIO's buckets at boot (Tempo hard-fails without its bucket, confirmed
live), and MinIO's own `HelmRelease` depends on the umbrella for the `root-credentials`
Secret; nesting the stack in the umbrella therefore deadlocks a fresh install
([ADR-0013](../adr/0013-observability-stack.md)). The four upstream charts are **direct
remote dependencies** of the observability chart (`repository: https://...`, no local
wrapper — Flux resolves a git-sourced chart's own top-level remote dependencies fine;
only _nested_ ones break, ADR-0012), each with `fullnameOverride` set so the in-cluster
Service names they use to reach each other (`kube-prometheus-stack-prometheus`, `loki`,
`tempo`, `otel-collector`, `alert-webhook-sink`) are fixed rather than derived from the
release name. Config lives in that chart's `values.yaml` under each dependency's name.

- **`prometheus-community/kube-prometheus-stack`** bundles Prometheus, Alertmanager,
  Grafana, kube-state-metrics and node-exporter (plus the `PrometheusRule`/
  `ServiceMonitor`/etc. CRDs, shipped as its own `crds` sub-dependency so `helm install`
  handles their lifecycle) — one chart covers metrics, infra metrics (via
  kube-state-metrics/node-exporter), Grafana, and the alerting machinery. Chosen over
  hand-rolling any of this: it's the standard, well-tested way to get this exact
  combination, and using the operator's `PrometheusRule`/Alertmanager-config values
  avoids writing and maintaining custom CRD templates.
- **`grafana/loki`** (`SingleBinary` deployment mode) and **`grafana/tempo`** (the monolithic
  chart) — right-sized for one small dev cluster, both **MinIO-backed** (`minio:9000`, MinIO's
  own standalone Flux `HelmRelease`, ADR-0012; buckets `loki`/`tempo`, created idempotently by
  its post-install job — configured on that `HelmRelease`'s `values:`).
  Credentials come from MinIO's generated `root-credentials` Secret via env vars
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`), never a literal value in `values.yaml`
  (`NFR-SEC`) — Loki's S3 client falls back to them automatically; Tempo needs
  `-config.expand-env=true` plus `${AWS_ACCESS_KEY_ID}`/`${AWS_SECRET_ACCESS_KEY}` placeholders
  in its own config, since its config loader (unlike Loki's) doesn't fall back to them itself.
- **`open-telemetry/opentelemetry-collector`** runs as a single `Deployment` (not a
  per-node `DaemonSet` — unnecessary on a single-node cluster), receiving OTLP
  (gRPC 4317 / HTTP 4318) and exporting: traces → Tempo (`otlp`), metrics → Prometheus
  (`prometheusremotewrite`, via `prometheus.prometheusSpec.enableRemoteWriteReceiver`),
  logs → Loki (`otlphttp`, Loki's native OTLP ingestion at `/otlp/v1/logs`, Loki 3.x+).

**Resource sizing deviation:** unlike our own custom subcharts, the vendored charts don't
use `global.resources.{small,medium,large}` — those tiers are sized for tiny Go services
(25m/32Mi …), not a real Prometheus/Grafana/Loki/Tempo stack. Each component sets its
own native `resources:` fields directly in `values.yaml` instead, sized for a small dev
cluster (the local `alert-webhook-sink` subchart still uses the tier convention).
Documented here rather than silently diverging.

**Correlation (trace ↔ log ↔ metric):** Grafana's Loki datasource has a `derivedFields`
regex that extracts `trace_id` from a log line and links to the Tempo datasource
(fixed `uid: tempo`/`uid: loki` on both so the cross-reference is stable); Tempo's
datasource has `tracesToLogsV2` pointing back at Loki. The Prometheus datasource is
auto-provisioned by kube-prometheus-stack. One starter dashboard ("BeekeepingIT
Platform Overview" — collector accepted spans/logs/metric-points per second + scrape
targets up) is added via Grafana's values-driven `dashboards`/`dashboardProviders`
keys, no hand-written ConfigMap template.

Since no service emits real telemetry yet (`#23`, the walking-skeleton services, is
still pending), [`infra/observability-smoke-test.sh`](../../infra/observability-smoke-test.sh)
fires one correlated trace+log+metric through the collector (via OTel's `telemetrygen`)
as a stand-in, to prove the pipeline and the trace↔log correlation end-to-end now. The
literal "walking-skeleton traces visible" AC gets closed for real once `#23` ships and
wires its Go service's OTel SDK to `otel-collector:4317` (tracked in
[`FOLLOWUPS.md`](../../FOLLOWUPS.md)).

[`infra/grafana-open.sh`](../../infra/grafana-open.sh) is a dev convenience for reaching
Grafana itself: it reads the chart-generated admin password out of the
`kube-prometheus-stack-grafana` Secret (never committed — see below), port-forwards the
service, and opens it in a browser.

**Alerting demo:** a custom `PrometheusRule` (injected via
`additionalPrometheusRulesMap`, no hand-written CRD template) fires `OtelCollectorDown`
when the collector's own scrape target goes down; Alertmanager's default route sends
every alert to `alert-webhook-sink` — a tiny local subchart
(`mendhak/http-https-echo`) that just logs each received webhook POST to stdout, so
delivery can be observed with no external account/secret. To simulate:
`kubectl scale deploy/otel-collector --replicas=0 -n beekeepingit-dev`, wait ~1 minute,
check `kubectl logs deploy/alert-webhook-sink -n beekeepingit-dev` for the
alert payload, then scale back to `1`.

**Not production alerting**: `alert-webhook-sink` is a local/dev verification aid, not
a real notification channel — wiring a real receiver (Slack/PagerDuty/email) is future
work, deliberately out of scope here (no external account/secret exists to wire yet).

## CI/CD

GitHub Actions runs a **path-filtered monorepo** pipeline (#88, D-9; see
[ADR-0014](../adr/0014-cicd-pipeline.md)). Workflows are split by concern:

- [`ci.yml`](../../.github/workflows/ci.yml) — repo-wide `task ci` (hygiene + per-language lint +
  test), self-discovering and green before any code lands.
- [`security-scan.yml`](../../.github/workflows/security-scan.yml) — supply-chain scanning, all
  three gates **blocking on HIGH,CRITICAL**: **Trivy `fs`** (dependency + secret) +
  **`govulncheck`** over every Go module + **Trivy `config`** (IaC misconfig — Helm/k8s/Actions/
  Dockerfiles), the last flipped from report-only once #89 triaged the pre-existing baseline (see
  the repo-root [`.trivyignore`](../../.trivyignore) for the individually-justified exceptions).
  This is the scanning stage EPIC-14 #89 shares and tunes.
- [`build-publish.yml`](../../.github/workflows/build-publish.yml) — a `detect` job emits a matrix
  of only the changed directories containing a `Dockerfile`; each builds → **Trivy image scan** →
  on merge to `main`, publishes to **ghcr.io** tagged by commit. **Dormant** until the first
  service ships a `Dockerfile` (empty matrix ⇒ skipped). macOS/iOS runners are deferred to M5 /
  EPIC-15 (a disabled placeholder job records this).
- [`helm-ci.yml`](../../.github/workflows/helm-ci.yml) — on any change under `infra/helm/**`:
  `helm dependency build`, `helm lint`, and `helm template` (base + each environment overlay) as a
  manifest-rendering dry-run. No live cluster is involved.
- [`helm-e2e.yml`](../../.github/workflows/helm-e2e.yml) — the live-cluster counterpart (`#154`):
  stands up an ephemeral k3d cluster via `infra/cluster/up.sh`, installs the umbrella release, waits
  for Postgres/Authentik/the domain-service Deployments, runs `helm test` (the `postgres` PostGIS
  smoke-query hook), then the walking-skeleton Playwright e2e (`client/e2e`, NFR-TST-1, `#162`) —
  login → create → offline edit → sync → convergence → logout — against that same cluster, and
  tears the cluster down regardless of outcome. Like `helm-ci.yml` it runs on every PR/push and
  checks path-relevance _inside_ the job (`dorny/paths-filter`) rather than on the trigger — so it
  can be a required check while still skipping the (minutes-long) live bring-up on PRs that don't
  touch `infra/helm/**`, `infra/cluster/**`, or `client/e2e/**`, reporting success in seconds for
  those.
- [`gitops-ci.yml`](../../.github/workflows/gitops-ci.yml) — kubeconform-validates the Flux
  manifests under `infra/gitops/**` (including the image-automation templates).

Deploy is **not** done from CI: on merge, CI publishes an image and **Flux image-automation**
commits the new tag into Git for Flux to reconcile — see GitOps below.

## GitOps (Flux)

[`infra/gitops/`](../../infra/gitops/) reconciles the umbrella chart above onto the `dev` cluster
from this repo — a manual `helm install`/`upgrade` is no longer how `dev` gets updated once a
change is merged to `main`. See the directory's own
[README](../../infra/gitops/README.md) for layout and day-to-day operation, and
[ADR-0009](../adr/0009-gitops-flux.md) for why Flux and why hand-wired (not `flux bootstrap`).

**Image-automation** closes the CI/CD loop (#88, [ADR-0014](../adr/0014-cicd-pipeline.md)): the
image-reflector + image-automation controllers watch ghcr.io and commit each new commit-tagged
image into `apps/dev/`, which Flux reconciles — so a merge deploys with no manual `kubectl`. The
engine + per-service templates live in
[`infra/gitops/image-automation/`](../../infra/gitops/image-automation/), **dormant** (outside the
reconciled paths) until the first service publishes an image and a Git write-credential is
provisioned (an EPIC-14 #89 secrets task).

## Not yet covered here

- Production-grade IdP (Authentik) flow/RBAC hardening and trusted-CA TLS for the gateway (both
  EPIC-14, `#15` — the `#84` seed is dev/CI-grade by design, see ADR-0010).
- PowerSync's real org-scoped Sync Rules and per-org sync-token connector (`docs/architecture/sync.md`,
  ADR-0006) — `#22` ships a placeholder sync-config and an IdP-JWKS stopgap (see
  `FOLLOWUPS.md`) since `apiaries`/`organizations` don't exist until `#23`/`#106`.
- End-to-end **publish→deploy** from CI — the #88 pipeline publishes images and lets Flux
  image-automation update manifests, but it is **dormant until the first service ships a
  `Dockerfile`**; that path is exercised then (see [ADR-0014](../adr/0014-cicd-pipeline.md)). Note
  the `postgres` subchart's `helm test` smoke-query hook _does_ now run against a live cluster in CI
  (`helm-e2e.yml`, `#154`) — it's no longer local-only.
