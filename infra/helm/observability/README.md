# `observability` — observability stack chart

The platform's observability stack (#87, `NFR-OBS-1`/`NFR-PER-1`): **OTel Collector →
Prometheus (metrics) / Loki (logs) / Tempo (traces) → Grafana**, plus a local/dev
Alertmanager webhook sink. Design background:
[`docs/architecture/platform.md#observability`](../../../docs/architecture/platform.md#observability)
/ [ADR-0013](../../../docs/adr/0013-observability-stack.md).

## Why it's not part of the `beekeepingit` umbrella chart

Loki/Tempo store to MinIO, and **Tempo validates its bucket eagerly at boot** — it
crash-loops until MinIO (its own Flux `HelmRelease`, ADR-0012) exists with the
`loki`/`tempo` buckets. MinIO's `HelmRelease` in turn `dependsOn` the umbrella (for the
generated `root-credentials` Secret). Nesting this stack inside the umbrella therefore
**deadlocks a fresh install** (umbrella never `Ready` because of Tempo → MinIO never
installs — found on the live dev cluster, not by `helm lint`/`template`). As its own
release, the ordering is acyclic: umbrella → MinIO → this
([`apps/dev/observability-helmrelease.yaml`](https://github.com/TiagoJVO/beekeepingit-gitops/blob/main/apps/dev/observability-helmrelease.yaml)
in the beekeepingit-gitops repo, `dependsOn: [beekeepingit, minio]`).

## Structure

The four upstream charts are **direct remote dependencies** (Flux's source-controller
resolves a git-sourced chart's own top-level remote dependencies; only _nested_
subchart-of-a-subchart dependencies break — ADR-0012). `charts/alert-webhook-sink/` is
our own local chart (same conventions as the umbrella's hand-rolled subcharts; it reads
`global.resources` tiers and the shared `beekeepingit.labels` helper, both provided
here too). Every component pins `fullnameOverride` so the Service names they wire to
each other (`kube-prometheus-stack-prometheus`, `loki`, `tempo`, `otel-collector`,
`alert-webhook-sink`) are release-name-independent.

`helm dependency build` here **needs network access** to the prometheus-community /
grafana / open-telemetry chart repos (unlike the umbrella, which is pure-local):

```sh
helm dependency build infra/helm/observability
helm lint infra/helm/observability
helm template observability infra/helm/observability
```

No `environments/` overlays — per-environment config lives on the Flux `HelmRelease`'s
`values:` (only `dev` deploys this today). Deploying without full GitOps mirrors the
standalone-`HelmRelease` pattern of Authentik/MinIO (`infra/README.md`): apply its
`HelmRelease` manifest directly.

## Credentials

Loki/Tempo read MinIO's generated `root-credentials` Secret via
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars — never a literal value in
`values.yaml` (`NFR-SEC`). Tempo additionally needs `-config.expand-env=true` because
its config loader doesn't fall back to `AWS_*` env vars the way Loki's S3 client does.
