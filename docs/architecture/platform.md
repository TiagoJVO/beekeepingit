# Platform: single k8s cluster + Helm umbrella chart

> **Status:** As-built (EPIC-13 #83). Intent: `NFR-ARC-1` (microservices, clear APIs),
> `NFR-ARC-3` (single cluster for v1, design for future scaling without forcing it),
> `D-1` (full microservices, still one cluster). Tech choice:
> [`requirements/tech-stack.md`](../../requirements/tech-stack.md) (`k8s + Helm`).

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

This is deliberately just the cluster — no backing services live here yet. Postgres+PostGIS,
Keycloak, MinIO and the gateway land with `#84`; the walking-skeleton Go services + PowerSync +
PWA land with `#23`. Both deploy through the umbrella chart below rather than standing up their
own release.

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
- **`charts/smoke/`**: a placeholder subchart (tiny `nginx-unprivileged` Deployment+Service)
  proving the whole umbrella→subchart wiring — dependency declaration, per-subchart values
  override, global resource tiers — actually renders and lints in CI before any real service
  exists. It is disabled in the `staging`/`prod` overlays and is removed once `#84`/`#23` add the
  first real subchart (tracked in [`FOLLOWUPS.md`](../../FOLLOWUPS.md)).

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

- Actual backing services and their resource requests (`#84`).
- The full path-filtered monorepo CI/CD pipeline (`#88`) — `helm-ci.yml` only covers the chart
  itself; CI publishing images and updating manifests for Flux to pick up also lands with `#88`.
