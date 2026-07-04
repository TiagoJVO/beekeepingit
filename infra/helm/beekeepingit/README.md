# `beekeepingit` — platform umbrella chart

Composes the whole BeekeepingIT platform into **one Helm release** on the single k8s cluster
(`NFR-ARC-1`, `NFR-ARC-3`, `D-1`). Design background:
[`docs/architecture/platform.md`](../../../docs/architecture/platform.md).

## Adding a new service subchart

Three shapes, depending on whether the service needs a maintained upstream chart, and if so
whether that chart can be vendored straight in or needs its own standalone Flux release (see
[ADR-0012](../../../docs/adr/0012-keycloak-minio-standalone-helmreleases.md) for the
standalone-release reasoning, and
[ADR-0010](../../../docs/adr/0010-platform-backing-services-provisioning.md) for what it
supersedes for `keycloak`/`minio`):

### Hand-rolled (no upstream chart, or not worth vendoring — e.g. `postgres`, `gateway`, `alert-webhook-sink`)

1. Create `charts/<service>/` as a normal Helm chart (its own `Chart.yaml`, `values.yaml`,
   `templates/`). Helm composes anything under `charts/` automatically.
2. Add it to this chart's `Chart.yaml` `dependencies:` (name, version, `repository:
file://charts/<service>`) — `helm lint` requires every subchart under `charts/` to be
   declared there.
3. Give it a top-level key in `values.yaml` matching its name (e.g. `<service>: {...}`) — that
   becomes the subchart's own `.Values` scope. Add an `enabled` field and gate every template
   with `{{- if .Values.enabled }}` if the service should be toggleable per environment.
4. Read shared config via `.Values.global` (namespace, resource tiers) — Helm passes `global`
   down to every subchart automatically. Don't hardcode CPU/memory; use
   `{{ index .Values.global.resources <tier> | toYaml }}` (`small`/`medium`/`large`).
5. Reuse the shared label helper: `{{- include "beekeepingit.labels" . | nindent 4 }}` (defined
   in `templates/_helpers.tpl`), plus your own `app.kubernetes.io/name`.

`charts/postgres/`, `charts/gateway/`, and `charts/alert-webhook-sink/` (#87 — a local/dev
Alertmanager receiver) are live examples of this pattern — copy whichever shape fits.

Note: a cluster-scoped **operator** (e.g. CloudNativePG, which `postgres`'s `Cluster` CR depends
on) is _not_ a subchart at all — it's installed once per cluster by `infra/cluster/up.sh`, the
same way k3d itself bundles Traefik. See `charts/postgres/Chart.yaml` and ADR-0010.

### Standalone Flux release (a maintained upstream chart exists, but Flux can't resolve it nested — e.g. `keycloak`, `minio`)

**Don't** nest a vendored chart as a Helm dependency of anything in this umbrella if the umbrella
itself is deployed by Flux straight from Git (see [`infra/gitops/`](../../gitops/)) — its
source-controller only resolves the umbrella's own top-level dependencies from what's checked
into Git, it does not recursively resolve a subchart's own nested vendored dependency (confirmed
directly: a pristine checkout without one, tried once, rendered zero of the vendored chart's
actual resources, silently — see ADR-0012, which supersedes the wrapper-chart approach this
repo used at first).

Instead: deploy the vendored chart as its **own standalone Flux `HelmRepository` + `HelmRelease`**
under [`infra/gitops/apps/dev/`](../../gitops/apps/dev/) (`keycloak-helmrelease.yaml`,
`minio-helmrelease.yaml` are live examples), with `dependsOn: [beekeepingit]` if it needs a
Secret/ConfigMap this umbrella creates. If the service needs supplementary resources the vendored
chart can't own itself (a generated-credential Secret — the standard `lookup` + `randAlphaNum`
idiom used throughout: preserve on `helm upgrade`, generate on first install, never a literal
value in git), add a **thin local chart** here (`charts/keycloak/`, `charts/minio/` are live
examples) with just those templates — no `dependencies:` section, nothing vendored. The standalone
`HelmRelease`'s `values:` then references those Secrets/ConfigMaps by their literal name (there's
no Helm templating inside a `HelmRelease`'s `values:` block), e.g.
`beekeepingit-keycloak-admin-credentials`. That name is only stable because all three
`HelmRelease`s **pin `spec.releaseName`** — Flux otherwise defaults an unset `releaseName` to
`<targetNamespace>-<HelmRelease name>` when they differ (which would make it
`beekeepingit-dev-beekeepingit-keycloak-admin-credentials`; confirmed against the live cluster).
Pin `spec.releaseName` on any new `HelmRelease` too, for the same reason (ADR-0012).

### Direct vendored dependency, no wrapper (the upstream chart needs no glue at all — e.g. the observability stack)

Off-the-shelf components that need nothing beyond values don't need a local `charts/<name>/`
directory at all — not even a wrapper:

1. Add it directly to this chart's `Chart.yaml` `dependencies:` with the upstream
   `repository:` URL (e.g. `https://prometheus-community.github.io/helm-charts`) and a
   pinned `version:` — `helm dependency build` fetches the `.tgz` straight from there
   (gitignored, like every subchart archive — see below).
2. Give it a top-level key in `values.yaml` matching its chart `name`, same as a local
   subchart — that's the config the upstream chart itself reads.
3. Set `fullnameOverride` on it (and on any of _its own_ nested subcharts you need a fixed
   name for, e.g. `grafana.fullnameOverride` inside `kube-prometheus-stack`) so the
   in-cluster Service names other components reference are fixed, not derived from the
   chart's default naming template — one less thing to reverse-engineer from generated
   output.
4. `condition: <name>.enabled` in the dependency entry gates the whole subchart the same
   way it does for a local one — set it `false` per environment in `environments/*.yaml`.

The observability stack (`kube-prometheus-stack`, `loki`, `tempo`,
`opentelemetry-collector` — #87, see
[`docs/architecture/platform.md#observability`](../../../docs/architecture/platform.md#observability))
is a live example of this pattern.

## Namespace & environments

`global.namespace` names the target namespace; it's created at install time
(`--namespace <ns> --create-namespace`, see [`infra/README.md`](../../README.md)), not by a
chart template, so `helm uninstall` never risks deleting a namespace shared with anything else.

`environments/{dev,staging,prod}.yaml` override `global.namespace`/`global.environment`/
`global.resources` per environment (`NFR-ARC-2` — designed for future environments without
forcing them; only `dev` is actually deployed today). Compose with `-f`:

```sh
helm template beekeepingit . -f environments/dev.yaml
helm install beekeepingit . -f environments/dev.yaml --namespace beekeepingit-dev --create-namespace
```

## Values schema

`values.schema.json` validates `global.environment` (`dev|staging|prod`), `global.namespace`,
and the three resource tiers (`requests`/`limits` × `cpu`/`memory`) — enforced automatically by
`helm lint`/`helm template`/`helm install`.

## Current subcharts

| Subchart                  | What it is                                                                                                                                        |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `postgres`                | PostgreSQL + PostGIS (D-6) via a CloudNativePG `Cluster` CR — schema-per-service + per-service credentials                                        |
| `keycloak`                | Generated admin credential + dev/CI-grade realm import for OIDC IdP Keycloak (D-7) — Keycloak itself is a separate Flux `HelmRelease` (ADR-0012) |
| `minio`                   | Generated root-credentials Secret for S3-compatible object storage (NFR-ARC-2) — MinIO itself is a separate Flux `HelmRelease` (ADR-0012)        |
| `gateway`                 | Ingress + self-signed TLS, reusing k3d's Traefik                                                                                                  |
| `kube-prometheus-stack`   | Prometheus + Alertmanager + Grafana + kube-state-metrics + node-exporter (`NFR-OBS-1`, #87)                                                       |
| `loki`                    | Logs (`NFR-OBS-1`, #87) — `SingleBinary` mode, MinIO-backed (the standalone `minio` `HelmRelease` above)                                          |
| `tempo`                   | Traces (`NFR-OBS-1`, #87) — monolithic chart, same MinIO-backed storage as `loki`                                                                 |
| `opentelemetry-collector` | OTLP receiver fanning out to the three above (#87)                                                                                                 |
| `alert-webhook-sink`      | Local/dev-only Alertmanager receiver (#87) — not production alerting                                                                              |

The former `charts/smoke/` placeholder that originally proved the umbrella-to-subchart wiring
(dependency declaration, values overrides, global resource tiers) before any real service existed
has been removed now that the ones above are real (`#84`, `#87`).

## Chart dependency archives aren't committed

`helm dependency build` fetches every dependency (local and third-party) into
`charts/*.tgz` — gitignored (`**/charts/*.tgz`, along with `Chart.lock`), so run it
yourself after cloning or changing a dependency version before `lint`/`template`/`install`
(the CI job does this automatically — see [`platform.md`](../../../docs/architecture/platform.md)).
