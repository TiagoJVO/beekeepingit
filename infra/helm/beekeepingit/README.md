# `beekeepingit` — platform umbrella chart

Composes the whole BeekeepingIT platform into **one Helm release** on the single k8s cluster
(`NFR-ARC-1`, `NFR-ARC-3`, `D-1`). Design background:
[`docs/architecture/platform.md`](../../../docs/architecture/platform.md).

## Adding a new service subchart

Two shapes, depending on whether a maintained upstream chart already exists for the service (see
[ADR-0010](../../../docs/adr/0010-platform-backing-services-provisioning.md) for the full
reasoning):

**Hand-rolled** (no upstream chart, or not worth vendoring — e.g. `postgres`, `gateway`):

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

`charts/postgres/` and `charts/gateway/` are live examples of this pattern.

**Vendored** (a maintained upstream chart exists — e.g. `keycloak`, `minio`): create a thin
**wrapper chart** at `charts/<service>/` whose own `Chart.yaml` declares the real upstream chart
as _its_ nested dependency (a remote `repository:`, not `file://`), and whose own `templates/`
add only what the vendored chart can't own itself — a generated-credential Secret (the standard
`lookup` + `randAlphaNum` idiom used throughout: preserve on `helm upgrade`, generate on first
install, never a literal value in git). The umbrella's own `Chart.yaml` then depends on the
wrapper (`file://charts/<service>`), same as a hand-rolled subchart. Because values.yaml isn't
templated, a vendored chart's own fields (its `resources:`, etc.) **can't** consume the shared
`global.resources.<tier>` lookup — set them directly in the wrapper's `values.yaml` instead, with
a comment noting they're hand-kept in sync. `charts/keycloak/` and `charts/minio/` are live
examples of this pattern; if the vendored chart's own dependency needs a fresh version, run `helm
dependency build charts/<service>` _before_ `helm dependency build .` at the umbrella root — the
umbrella only picks up what's already resolved inside the wrapper.

Note: a cluster-scoped **operator** (e.g. CloudNativePG, which `postgres`'s `Cluster` CR depends
on) is _not_ a subchart at all — it's installed once per cluster by `infra/cluster/up.sh`, the
same way k3d itself bundles Traefik. See `charts/postgres/Chart.yaml` and ADR-0010.

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

| Subchart   | What it is                                                                                                 |
| ---------- | ---------------------------------------------------------------------------------------------------------- |
| `postgres` | PostgreSQL + PostGIS (D-6) via a CloudNativePG `Cluster` CR — schema-per-service + per-service credentials |
| `keycloak` | OIDC IdP (D-7) — wraps `codecentric/keycloakx`; dev/CI-grade realm import                                  |
| `minio`    | S3-compatible object storage (NFR-ARC-2) — wraps the official `charts.min.io` chart                        |
| `gateway`  | Ingress + self-signed TLS, reusing k3d's Traefik                                                           |

The former `charts/smoke/` placeholder that originally proved the umbrella-to-subchart wiring
(dependency declaration, values overrides, global resource tiers) before any real service existed
has been removed now that the four above are real (`#84`).
