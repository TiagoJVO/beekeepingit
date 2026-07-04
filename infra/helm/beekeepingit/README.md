# `beekeepingit` — platform umbrella chart

Composes the whole BeekeepingIT platform into **one Helm release** on the single k8s cluster
(`NFR-ARC-1`, `NFR-ARC-3`, `D-1`). Design background:
[`docs/architecture/platform.md`](../../../docs/architecture/platform.md).

## Adding a new service subchart

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

The `charts/smoke/` subchart is a live example of this exact pattern — copy its shape.

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

## The `smoke` subchart

`charts/smoke/` is a placeholder (a tiny `nginx-unprivileged` Deployment + Service) that proves
the umbrella-to-subchart wiring (dependency declaration, values overrides, global resource
tiers) actually works in CI before any real service exists. It is **not** a real component —
remove it once `#84` or `#23` adds the first real service subchart (tracked in
[`FOLLOWUPS.md`](../../../FOLLOWUPS.md)).
