# 0008 — Observability stack: OTel Collector + kube-prometheus-stack + Loki + Tempo

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

Two things this stack can't fully close yet, and aren't silently glossed over:

- **No object storage yet** — MinIO lands with #84, so Loki/Tempo start on
  filesystem/local-disk storage.
- **No real telemetry source yet** — #23 (walking-skeleton services) hasn't landed, so
  nothing in the cluster emits OTel data on its own.

## Decision

1. **Vendor upstream charts as direct umbrella dependencies** rather than a local
   `charts/<name>/` wrapper — see the "vendoring a third-party chart" convention added to
   [`infra/helm/beekeepingit/README.md`](../../infra/helm/beekeepingit/README.md). Pinned
   versions: `kube-prometheus-stack` 87.10.0, `loki` 7.0.0, `tempo` 1.24.4,
   `opentelemetry-collector` 0.162.0 (from each chart repo's `index.yaml` at
   implementation time).
2. **`kube-prometheus-stack`** (not separate Prometheus + Grafana + Alertmanager charts)
   for Prometheus, Alertmanager, Grafana, kube-state-metrics, and node-exporter in one
   chart, including the `PrometheusRule`/`ServiceMonitor`/etc. CRDs as its own `crds`
   sub-dependency. This satisfies "Prometheus scrapes service/infra metrics" (infra
   metrics via kube-state-metrics/node-exporter) and gives the alerting/`PrometheusRule`
   machinery for free.
3. **Loki (`SingleBinary` mode) + Tempo (monolithic chart)**, both filesystem/local-disk
   storage, no distributed mode — right-sized for one small dev cluster, and there's no
   object store to point at yet anyway.
4. **OTel Collector as a single `Deployment`** (not a `DaemonSet` — unneeded on a
   single-node cluster), OTLP receiver, exporting traces→Tempo (`otlp`),
   metrics→Prometheus (`prometheusremotewrite` via
   `enableRemoteWriteReceiver`), logs→Loki (`otlphttp`, native OTLP ingestion).
5. **Resource sizing set natively per component**, not via the umbrella's shared
   `global.resources.{small,medium,large}` tiers — those were sized for tiny custom Go
   services (25m/32Mi …), and forcing a real Prometheus/Grafana/Loki/Tempo stack into
   them would misrepresent actual footprints. A documented, deliberate deviation.
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

- Two follow-ups are tracked in [`FOLLOWUPS.md`](../../FOLLOWUPS.md): swap Loki/Tempo to
  MinIO-backed storage once #84 lands, and replace the `telemetrygen` verification with
  #23's real service traffic once it ships (closing #87's last AC literally).
- CRD lifecycle caveat: `kube-prometheus-stack`'s CRDs install cleanly via `helm install`
  (its own `crds` sub-dependency) but, like all Helm CRDs, aren't auto-upgraded by
  `helm upgrade` — a future chart-version bump needing new/changed CRDs will need a
  manual `kubectl apply`, per the chart's own upgrade notes.
- `alert-webhook-sink` must not be mistaken for production alerting — it's an explicit
  local/dev-only stand-in (see `platform.md`).
- `helm dependency build` now needs network access to three chart repos
  (`prometheus-community`, `grafana`, `open-telemetry`) — already true of any Helm
  umbrella chart with third-party dependencies, and unchanged for CI (`helm-ci.yml`
  already runs `helm dependency build`).

## Alternatives considered

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
