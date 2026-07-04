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
  [ADR-0008](../adr/0008-platform-backing-services-provisioning.md)). `down.sh` needs no change:
  deleting the k3d cluster removes it along with everything else.

## Helm umbrella chart

[`infra/helm/beekeepingit/`](../../infra/helm/beekeepingit/) is one Helm chart that composes
every service as a **subchart** under `charts/`, so the whole platform deploys/upgrades as one
release. Conventions (namespace, resource tiers, values schema, how a service subchart plugs in)
are documented in the chart's own [README](../../infra/helm/beekeepingit/README.md) — this
section covers the *why*.

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
- **Vendored vs hand-rolled subcharts** (`#84`, [ADR-0008](../adr/0008-platform-backing-services-provisioning.md)):
  `postgres` (a CloudNativePG `Cluster` CR + per-service credential Secrets) and `gateway` (a
  portable `Ingress` + self-signed TLS Secret, reusing k3d's Traefik) are hand-rolled — there's
  nothing to vendor for either. `keycloak` and `minio` are thin **wrapper charts**: each declares
  a real upstream chart (`codecentric/keycloakx`, the official `charts.min.io` MinIO chart) as its
  own nested dependency, adding only what the vendored chart can't own itself (a generated
  credential Secret; for Keycloak, also the dev/CI-grade realm import). The former `charts/smoke/`
  placeholder that originally proved this wiring end-to-end has been removed now that real
  subcharts exist.

## CI gate

[`.github/workflows/helm-ci.yml`](../../.github/workflows/helm-ci.yml) runs on any change under
`infra/helm/**`: `helm dependency build`, `helm lint` (base + each environment overlay), and
`helm template` (base + each environment overlay) as a manifest-rendering dry-run. No live
cluster is involved — deploying to the cluster from CI is `#86` (GitOps)/`#88` (CI/CD pipeline).

## Not yet covered here

- Production-grade Keycloak realm/RBAC hardening and trusted-CA TLS for the gateway (both
  EPIC-14, `#15` — the `#84` seed is dev/CI-grade by design, see ADR-0008).
- GitOps reconciliation (Flux is installed on the dev cluster but not bootstrapped against this
  repo yet — deferred to `#86` per the `local-dev-environment` setup notes).
- The full path-filtered monorepo CI/CD pipeline (`#88`) — `helm-ci.yml` only covers the chart
  itself, and has no live cluster to run the `postgres` subchart's `helm test` smoke-query hook
  against yet (that's a developer's local `beekeeping` k3d cluster today).
