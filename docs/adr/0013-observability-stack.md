# 0013 — Observability stack: OTel Collector + kube-prometheus-stack + Loki + Tempo

- **Status:** Accepted
- **Date:** 2026-07-04
- **Issue / Epic:** #87 / EPIC-13 (#14) · **Milestone:** M0
- **Requirements:** NFR-OBS-1, NFR-PER-1
- **Tech choice:** [`requirements/tech-stack.md`](../../requirements/tech-stack.md)
  ("OpenTelemetry + Prometheus + Grafana + Loki/Tempo", status "Proposed" — this ADR is
  its as-built record)
- **Design:** [`docs/architecture/platform.md#observability`](../architecture/platform.md#observability)

## Context

NFR-OBS-1 requires logging, monitoring, and alerting so the platform can be operated in
production. #87 is unblocked (its only dependency, #83, is merged) and independent of
#84 (backing services) and #23 (walking-skeleton services) — so the stack can be stood
up now, ahead of both.

The umbrella chart (#83) so far shows one subchart pattern: a fully custom local chart
(`charts/smoke/`, a placeholder). Prometheus, Alertmanager, Grafana, Loki, and Tempo are
each substantial, well-tested open-source projects with mature Helm charts — hand-rolling
equivalents as raw manifests would be far more code and risk for no benefit over vendoring.

One thing this stack can't fully close yet, and isn't silently glossed over:

- **No real telemetry source yet** — #23 (walking-skeleton services) hasn't landed, so
  nothing in the cluster emits OTel data on its own.

Two mid-flight evolutions shaped the final form (this branch was open while #84/#136/#138
landed on `main`):

- Loki/Tempo initially shipped on filesystem/local-disk storage (no object store existed
  yet); once #84's MinIO landed, both were rewired to it — see decision 3.
- The stack initially lived **inside the beekeepingit umbrella chart** as direct vendored
  dependencies. A live test against the real dev cluster (via Flux, tracking this branch)
  exposed a **fresh-install deadlock** that `helm lint`/`template` cannot catch: MinIO's
  `HelmRelease` has `dependsOn: [beekeepingit]` (it consumes the umbrella's generated
  `root-credentials` Secret), while the umbrella now contained **Tempo, which validates
  its S3 bucket eagerly at boot and hard-fails** (`ListObjects ... The specified bucket
does not exist`, crash-loop — confirmed live) until MinIO exists. So the umbrella can
  never become `Ready` on a fresh cluster, and MinIO never installs. Loki tolerates the
  missing bucket at startup (fails later on flush), so it masked the problem; Tempo
  surfaced it. This forced decision 1 below.

## Decision

1. **The observability stack is its own chart + Flux `HelmRelease`, not part of the
   beekeepingit umbrella.** [`infra/helm/observability/`](../../infra/helm/observability/)
   declares the four upstream charts as direct remote dependencies (no local wrapper —
   Flux's source-controller resolves a GitRepository-sourced chart's own **top-level**
   remote dependencies fine, verified live; only _nested_ subchart-of-a-subchart
   dependencies break, per [ADR-0012](0012-keycloak-minio-standalone-helmreleases.md)),
   plus the local `alert-webhook-sink` chart.
   [`infra/gitops/apps/dev/observability-helmrelease.yaml`](../../infra/gitops/apps/dev/observability-helmrelease.yaml)
   deploys it with `dependsOn: [beekeepingit, minio]`, giving the acyclic layering a
   fresh cluster needs: umbrella (creates the Secret) → MinIO (creates the buckets) →
   observability (Tempo boots against an existing bucket). Pinned versions:
   `kube-prometheus-stack` 87.10.0, `loki` 7.0.0, `tempo` 1.24.4,
   `opentelemetry-collector` 0.162.0 (from each chart repo's `index.yaml` at
   implementation time).
2. **`kube-prometheus-stack`** (not separate Prometheus + Grafana + Alertmanager charts)
   for Prometheus, Alertmanager, Grafana, kube-state-metrics, and node-exporter in one
   chart, including the `PrometheusRule`/`ServiceMonitor`/etc. CRDs as its own `crds`
   sub-dependency. This satisfies "Prometheus scrapes service/infra metrics" (infra
   metrics via kube-state-metrics/node-exporter) and gives the alerting/`PrometheusRule`
   machinery for free.
3. **Loki (`SingleBinary` mode) + Tempo (monolithic chart)**, no distributed mode — right-sized
   for one small dev cluster. Both are **MinIO-backed**, buckets `loki`/`tempo` (created
   idempotently by MinIO's own post-install job), with credentials from MinIO's generated
   `root-credentials` Secret injected as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env
   vars — never a literal value in `values.yaml` (`NFR-SEC`). Loki's S3 client falls back
   to these env vars automatically; Tempo's config loader doesn't, so it additionally
   needs `-config.expand-env=true` plus `${AWS_ACCESS_KEY_ID}`/`${AWS_SECRET_ACCESS_KEY}`
   placeholders in its own config. Endpoint is `minio:9000` (MinIO's standalone
   `HelmRelease`, pinned `releaseName: minio`, ADR-0012) — the `loki`/`tempo` bucket
   config lives on that `HelmRelease`'s `values:`
   (`infra/gitops/apps/dev/minio-helmrelease.yaml`), where the chart that creates
   buckets actually runs.
4. **OTel Collector as a single `Deployment`** (not a `DaemonSet` — unneeded on a
   single-node cluster), OTLP receiver, exporting traces→Tempo (`otlp`),
   metrics→Prometheus (`prometheusremotewrite` via
   `enableRemoteWriteReceiver`), logs→Loki (`otlphttp`, native OTLP ingestion).
5. **Resource sizing set natively per component**, not via the shared
   `global.resources.{small,medium,large}` tiers — those were sized for tiny custom Go
   services (25m/32Mi …), and forcing a real Prometheus/Grafana/Loki/Tempo stack into
   them would misrepresent actual footprints. A documented, deliberate deviation (the
   local `alert-webhook-sink` chart still uses the tier convention).
6. **Alerting receiver: a local `alert-webhook-sink` subchart** (`mendhak/http-https-echo`,
   logs every POST to stdout), not a real external channel — no Slack/PagerDuty
   account/secret exists yet to wire one. A custom `PrometheusRule` (via
   `additionalPrometheusRulesMap`, no hand-written CRD template) fires when the OTel
   Collector's own target goes down, satisfying the "simulated failure condition" AC
   without needing #23's services.
7. **Correlation proven with a verification script, not a permanent workload**:
   [`infra/observability-smoke-test.sh`](../../infra/observability-smoke-test.sh) uses
   OTel's `telemetrygen` to fire one correlated trace+log+metric through the collector,
   demonstrating the Loki↔Tempo `derivedFields`/`tracesToLogsV2` wiring end-to-end ahead
   of #23.

## Consequences

- A **live test against the real dev cluster** (Flux pointed at this branch) validated
  most of the stack first-try: Loki, Prometheus, Grafana (datasources + starter
  dashboard), OTel Collector, kube-state-metrics, node-exporter and the alert sink all
  came up `Running`; Tempo exposed the deadlock that motivated decision 1. A re-test of
  the final split layout (and of the trace↔log correlation + alerting walkthroughs) is
  tracked in [`FOLLOWUPS.md`](../../FOLLOWUPS.md), alongside replacing the `telemetrygen`
  verification with `#23`'s real service traffic once it ships.
- **Removing a whole subchart from a live Helm release doesn't reliably prune all its
  resources** — observed directly while backing the test out: reverting the release to a
  chart without the stack left ~90 orphaned resources (Deployments, ConfigMaps, RBAC,
  webhooks, CRs) needing manual deletion. With the stack as its own release this becomes
  a non-issue going forward (`helm uninstall observability` / Flux prune owns the whole
  lifecycle), but it's worth knowing before ever folding a large subchart back into an
  existing release.
- The `beekeepingit` umbrella chart is back to **pure local `file://` dependencies** (no
  network in its `helm dependency build`); the observability chart is the one needing
  network access to the three upstream chart repos (`prometheus-community`, `grafana`,
  `open-telemetry`) — `helm-ci.yml` validates both.
- A plain `helm install` of the umbrella **no longer deploys any observability
  workload** — like Keycloak/MinIO (ADR-0012), getting the stack without full GitOps
  means applying its `HelmRelease` manifest directly (see `infra/README.md`).
- CRD lifecycle caveat: `kube-prometheus-stack`'s CRDs install cleanly via `helm install`
  (its own `crds` sub-dependency) but, like all Helm CRDs, aren't auto-upgraded by
  `helm upgrade` — a future chart-version bump needing new/changed CRDs will need a
  manual `kubectl apply`, per the chart's own upgrade notes.
- `alert-webhook-sink` must not be mistaken for production alerting — it's an explicit
  local/dev-only stand-in (see `platform.md`).

## Alternatives considered

- **Keeping the stack inside the umbrella and breaking the deadlock by dropping MinIO's
  `dependsOn` + install retries** — rejected: it relies on install-timing races (the
  Secret happens to be applied before MinIO's first attempt; Tempo crash-loops until the
  buckets appear) instead of an explicit, verifiable ordering, and ADR-0012 already
  established `dependsOn` as how this repo expresses release ordering.
- **Hand-rolled manifests instead of vendored charts** — rejected: far more code to
  write and maintain for functionality these charts already provide, with more
  correctness risk (Prometheus/Alertmanager/Loki/Tempo configuration has a lot of
  surface area).
- **A single all-in-one "LGTM" dev container image** — rejected: not representative of
  how this would run in staging/prod (`NFR-ARC-2` — design for future environments
  without forcing them now), and each component can't be resourced, scaled, or
  toggled independently.
- **Loki/Tempo distributed mode now** — rejected: unnecessary complexity and resource
  footprint for one small dev cluster; revisit only if/when scale demands it.
- **Real external Alertmanager receiver (Slack/PagerDuty) now** — rejected for this PR:
  no such account/webhook exists yet, and NFR-SEC forbids inventing a secret to wire
  it; the in-cluster webhook sink proves the same delivery mechanism without one.
