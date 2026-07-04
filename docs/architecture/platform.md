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

Postgres+PostGIS, Keycloak, MinIO and the gateway landed with `#84` (see below); the
walking-skeleton Go services + PowerSync + PWA land with `#23`. Both deploy through the umbrella
chart below rather than standing up their own release.

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
  nothing to vendor for either. `keycloak` and `minio` are thin **wrapper charts**: each declares
  a real upstream chart (`codecentric/keycloakx`, the official `charts.min.io` MinIO chart) as its
  own nested dependency, adding only what the vendored chart can't own itself (a generated
  credential Secret; for Keycloak, also the dev/CI-grade realm import).
- **Vendoring a third-party chart with no wrapper at all**: see Observability below, which pulls
  `kube-prometheus-stack`/`loki`/`tempo`/`opentelemetry-collector` straight from their upstream
  repos as direct `Chart.yaml` dependencies (`repository: https://...`, not even a local
  `charts/<name>/` wrapper — there's nothing for one to add). This sits alongside the wrapper
  pattern above and the "own custom subchart" pattern (`charts/alert-webhook-sink/` is a live
  example of that shape) — all three are documented in the chart's own README.
- The former `charts/smoke/` placeholder (proved the umbrella→subchart wiring before any real
  service existed) was removed once `#84`/`#87` added the first real subcharts.

## Observability

Stack per `requirements/tech-stack.md`: **OpenTelemetry Collector → Prometheus (metrics) /
Loki (logs) / Tempo (traces) → Grafana**, satisfying `NFR-OBS-1` (logging, monitoring,
alerting) and contributing to `NFR-PER-1`. All four components are vendored upstream
charts (see above), each with `fullnameOverride` set so the in-cluster Service names
they reference to reach each other (`kube-prometheus-stack-prometheus`, `loki`, `tempo`,
`otel-collector`) are fixed rather than derived from each chart's own naming template.
Config lives in the umbrella's `values.yaml` under each chart's name.

- **`prometheus-community/kube-prometheus-stack`** bundles Prometheus, Alertmanager,
  Grafana, kube-state-metrics and node-exporter (plus the `PrometheusRule`/
  `ServiceMonitor`/etc. CRDs, shipped as its own `crds` sub-dependency so `helm install`
  handles their lifecycle) — one chart covers metrics, infra metrics (via
  kube-state-metrics/node-exporter), Grafana, and the alerting machinery. Chosen over
  hand-rolling any of this: it's the standard, well-tested way to get this exact
  combination, and using the operator's `PrometheusRule`/Alertmanager-config values
  avoids writing and maintaining custom CRD templates.
- **`grafana/loki`** (`SingleBinary` deployment mode) and **`grafana/tempo`** (the monolithic
  chart) — right-sized for one small dev cluster, both **MinIO-backed** (`#84`'s `minio`
  subchart; buckets `loki`/`tempo`, created idempotently by its post-install job). Credentials
  come from MinIO's generated `root-credentials` Secret via env vars
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`), never a literal value in `values.yaml`
  (`NFR-SEC`) — Loki's S3 client falls back to them automatically; Tempo needs
  `-config.expand-env=true` plus `${AWS_ACCESS_KEY_ID}`/`${AWS_SECRET_ACCESS_KEY}` placeholders
  in its own config, since its config loader (unlike Loki's) doesn't fall back to them itself.
- **`open-telemetry/opentelemetry-collector`** runs as a single `Deployment` (not a
  per-node `DaemonSet` — unnecessary on a single-node cluster), receiving OTLP
  (gRPC 4317 / HTTP 4318) and exporting: traces → Tempo (`otlp`), metrics → Prometheus
  (`prometheusremotewrite`, via `prometheus.prometheusSpec.enableRemoteWriteReceiver`),
  logs → Loki (`otlphttp`, Loki's native OTLP ingestion at `/otlp/v1/logs`, Loki 3.x+).

**Resource sizing deviation:** unlike our own custom subcharts, these don't use
`global.resources.{small,medium,large}` — those tiers are sized for tiny Go services
(25m/32Mi …), not a real Prometheus/Grafana/Loki/Tempo stack. Each component sets its
own native `resources:` fields directly in `values.yaml` instead, sized for a small dev
cluster. Documented here rather than silently diverging from the shared-tiers
convention.

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
check `kubectl logs deploy/beekeepingit-alert-webhook-sink -n beekeepingit-dev` for the
alert payload, then scale back to `1`.

**Not production alerting**: `alert-webhook-sink` is a local/dev verification aid, not
a real notification channel — wiring a real receiver (Slack/PagerDuty/email) is future
work, deliberately out of scope here (no external account/secret exists to wire yet).

## CI gate

[`.github/workflows/helm-ci.yml`](../../.github/workflows/helm-ci.yml) runs on any change under
`infra/helm/**`: `helm dependency build`, `helm lint` (base + each environment overlay), and
`helm template` (base + each environment overlay) as a manifest-rendering dry-run. No live
cluster is involved — deploying to the cluster from CI is `#86` (GitOps)/`#88` (CI/CD pipeline).

## GitOps (Flux)

[`infra/gitops/`](../../infra/gitops/) reconciles the umbrella chart above onto the `dev` cluster
from this repo — a manual `helm install`/`upgrade` is no longer how `dev` gets updated once a
change is merged to `main`. See the directory's own
[README](../../infra/gitops/README.md) for layout and day-to-day operation, and
[ADR-0009](../adr/0009-gitops-flux.md) for why Flux and why hand-wired (not `flux bootstrap`).

## Not yet covered here

- Production-grade Keycloak realm/RBAC hardening and trusted-CA TLS for the gateway (both
  EPIC-14, `#15` — the `#84` seed is dev/CI-grade by design, see ADR-0010).
- The full path-filtered monorepo CI/CD pipeline (`#88`) — `helm-ci.yml` only covers the chart
  itself, and has no live cluster to run the `postgres` subchart's `helm test` smoke-query hook
  against yet (that's a developer's local `beekeeping` k3d cluster today); CI publishing images
  and updating manifests for Flux to pick up also lands with `#88`.
