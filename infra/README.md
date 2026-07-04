# Infrastructure

The single-cluster Kubernetes platform (`NFR-ARC-3`) and the Helm umbrella chart that deploys
it (`NFR-ARC-1`, `D-1`). See [`docs/architecture/platform.md`](../docs/architecture/platform.md)
for the as-built design; intent/decisions live in
[`requirements/decisions.md`](../requirements/decisions.md) and
[`requirements/tech-stack.md`](../requirements/tech-stack.md).

## Quickstart

```sh
# 1. Bring up the local cluster (k3d, idempotent) — also installs/upgrades the
#    CloudNativePG operator, a cluster-scoped prerequisite for the `postgres`
#    subchart (see charts/postgres/Chart.yaml and ADR-0010)
infra/cluster/up.sh

# 2. Install (or upgrade) the platform
infra/cluster/with-lock.sh helm install beekeepingit infra/helm/beekeepingit \
  -f infra/helm/beekeepingit/environments/dev.yaml \
  --namespace beekeepingit-dev --create-namespace

# ...later, after changing values or adding a service subchart:
infra/cluster/with-lock.sh helm upgrade beekeepingit infra/helm/beekeepingit \
  -f infra/helm/beekeepingit/environments/dev.yaml \
  --namespace beekeepingit-dev

# 3. Smoke-test the backing services (Postgres/PostGIS; #84)
helm test beekeepingit --namespace beekeepingit-dev

# 4. Tear down
infra/cluster/with-lock.sh helm uninstall beekeepingit --namespace beekeepingit-dev
infra/cluster/down.sh
```

Requires `k3d`, `kubectl`, `helm`, and `flock` on `PATH`. On Windows, run these from the WSL2
environment (see the local-dev-environment notes) — the scripts are plain POSIX `bash`.

## Sharing the local cluster across concurrent sessions

The local `beekeeping` k3d cluster is one shared, mutable resource — if two sessions (e.g. two
concurrent Claude Code agents in different git worktrees) run `infra/cluster/up.sh`/`down.sh` or
`helm install/upgrade/uninstall` against it at the same time, they can race: one tearing down the
cluster (or a release) while the other is mid-operation, causing exactly the kind of node/pod
churn that looks like environment flakiness but is actually a collision.

`up.sh`/`down.sh` take a `flock`-based lock on `/tmp/k3d-beekeeping.lock` themselves, so they
serialize automatically against each other (from any worktree — the lock is keyed by the cluster
name, not by path, since different worktrees are different directories on disk but the same
lockfile path is shared across all of them within one WSL2 instance). For anything else that
mutates the cluster — `helm install`/`upgrade`/`uninstall`, ad-hoc `kubectl apply` — wrap it with
[`infra/cluster/with-lock.sh`](cluster/with-lock.sh), which takes the same lock:

```sh
infra/cluster/with-lock.sh helm install beekeepingit infra/helm/beekeepingit -f ...
```

Read-only commands (`kubectl get`, `helm test`, `helm lint`/`template`) don't need the lock.

This is a **local-dev-only** convention — it has no bearing on CI (`.github/workflows/helm-ci.yml`
never touches a live cluster, and future live-cluster CI on GitHub-hosted runners doesn't share a
filesystem with this machine or across concurrent runs, so `flock` wouldn't apply there anyway).

## Layout

| Path                                       | What it is                                                                                                                         |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`cluster/`](cluster/)                     | Local k8s cluster (k3d) bring-up (`up.sh`) and teardown (`down.sh`)                                                                |
| [`helm/beekeepingit/`](helm/beekeepingit/) | The Helm **umbrella chart** — see its own [README](helm/beekeepingit/README.md) for the subchart/values conventions                |
| [`gitops/`](gitops/)                       | **Flux** GitOps wiring that reconciles the umbrella chart onto the cluster from this repo — see its own [README](gitops/README.md) |

Postgres+PostGIS, Keycloak, MinIO and the gateway (**#84**) are the umbrella chart's first real
subcharts; the walking-skeleton services + PowerSync + PWA subcharts land with **#23**. Both wire
into this umbrella chart rather than standing up their own release.
