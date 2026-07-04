# Infrastructure

The single-cluster Kubernetes platform (`NFR-ARC-3`) and the Helm umbrella chart that deploys
it (`NFR-ARC-1`, `D-1`). See [`docs/architecture/platform.md`](../docs/architecture/platform.md)
for the as-built design; intent/decisions live in
[`requirements/decisions.md`](../requirements/decisions.md) and
[`requirements/tech-stack.md`](../requirements/tech-stack.md).

## Quickstart

```sh
# 1. Bring up the local cluster (k3d, idempotent)
infra/cluster/up.sh

# 2. Install (or upgrade) the platform
helm install beekeepingit infra/helm/beekeepingit \
  -f infra/helm/beekeepingit/environments/dev.yaml \
  --namespace beekeepingit-dev --create-namespace

# ...later, after changing values or adding a service subchart:
helm upgrade beekeepingit infra/helm/beekeepingit \
  -f infra/helm/beekeepingit/environments/dev.yaml \
  --namespace beekeepingit-dev

# 3. Tear down
helm uninstall beekeepingit --namespace beekeepingit-dev
infra/cluster/down.sh
```

Requires `k3d`, `kubectl`, and `helm` on `PATH`. On Windows, run these from the WSL2 environment
(see the local-dev-environment notes) — the scripts are plain POSIX `bash`.

## Layout

| Path                                       | What it is                                                                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| [`cluster/`](cluster/)                     | Local k8s cluster (k3d) bring-up (`up.sh`) and teardown (`down.sh`)                                                 |
| [`helm/beekeepingit/`](helm/beekeepingit/) | The Helm **umbrella chart** — see its own [README](helm/beekeepingit/README.md) for the subchart/values conventions |
| [`gitops/`](gitops/) | **Flux** GitOps wiring that reconciles the umbrella chart onto the cluster from this repo — see its own [README](gitops/README.md) |

Environment-specific services (Postgres, Keycloak, MinIO, gateway) land with **#84**; the
walking-skeleton services + PowerSync + PWA subcharts land with **#23**. Both wire into this
umbrella chart rather than standing up their own release.
