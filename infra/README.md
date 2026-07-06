# Infrastructure

The single-cluster Kubernetes platform (`NFR-ARC-3`) and the Helm umbrella chart that deploys
it (`NFR-ARC-1`, `D-1`). See [`docs/architecture/platform.md`](../docs/architecture/platform.md)
for the as-built design; intent/decisions live in
[`requirements/decisions.md`](../requirements/decisions.md) and
[`requirements/tech-stack.md`](../requirements/tech-stack.md).

## Quickstart

A single command brings up the whole local dev environment (`#22`, `NFR-ARC-2`/`NFR-ARC-3`) —
Postgres+PostGIS, Keycloak, PowerSync, MinIO, and the gateway/ingress — and another tears it down:

```sh
infra/cluster/dev-up.sh    # idempotent: safe to re-run against an already-provisioned cluster
infra/cluster/dev-down.sh  # uninstalls the releases, then deletes the k3d cluster
```

Requires `k3d`, `kubectl`, `helm`, `flux`, and `flock` on `PATH`. On Windows, run these from the
WSL2 environment (see the local-dev-environment notes) — the scripts are plain POSIX `bash`.

`dev-up.sh` does NOT apply `infra/gitops/clusters/dev/` (the one-time GitOps bootstrap that makes
Flux auto-sync from this repo's `main` branch) — that would deploy the umbrella chart from
`main`, ignoring whatever's checked out locally, the opposite of what a pre-merge dev/test loop
needs. It also skips the observability stack (`#87`) — not one of `#22`'s components, and its
HelmRelease depends on that same bootstrap `GitRepository`. See
[`infra/gitops/README.md`](gitops/README.md) for the post-merge bootstrap step.

### Step-by-step (what `dev-up.sh`/`dev-down.sh` actually do)

```sh
# 1. Bring up the local cluster (k3d, idempotent) — also installs/upgrades the
#    CloudNativePG operator, a cluster-scoped prerequisite for the `postgres`
#    subchart (see charts/postgres/Chart.yaml and ADR-0010)
infra/cluster/up.sh

# 2. Install/upgrade the Flux controllers (idempotent) — keycloak/minio below are
#    Flux HelmReleases, so this is a real prerequisite, not optional.
flux install --components-extra=image-reflector-controller,image-automation-controller

# 3. Fetch chart dependencies (local + vendored third-party, see the chart's README) —
#    re-run after cloning, after changing a dependency version, AND after editing any
#    local subchart's templates/values (helm installs the packaged charts/*.tgz
#    snapshot under this dir, not the live source — a stale snapshot silently
#    installs old content otherwise, see FOLLOWUPS.md).
helm dependency build infra/helm/beekeepingit

# 4. Install (or upgrade) the platform. Deliberately no `--wait`: PowerSync can't
#    pass its readiness probe until the postgres subchart's schema-grants Job (a
#    post-install hook, since the `powersync` role doesn't exist yet at install
#    time) has granted it access to `powersync_storage` — and Helm only runs
#    post-install hooks *after* `--wait` is satisfied for the main resources, so
#    waiting here would deadlock PowerSync against its own grant.
infra/cluster/with-lock.sh helm upgrade --install beekeepingit infra/helm/beekeepingit \
  -f infra/helm/beekeepingit/environments/dev.yaml \
  --namespace beekeepingit-dev --create-namespace

# 5. Wait for postgres explicitly instead (see step 4's note). `dev-up.sh`'s
#    actual `wait_for_pod` helper polls until a matching pod exists before this
#    call — `kubectl wait` errors immediately ("no matching resources found")
#    rather than waiting, if the Deployment/StatefulSet/HelmRelease that owns
#    the pod hasn't created it yet:
kubectl -n beekeepingit-dev wait --for=condition=ready pod \
  -l cnpg.io/cluster=beekeepingit-postgres --timeout=180s

# 6. Keycloak/MinIO are separate Flux HelmReleases (ADR-0012), not part of the
#    umbrella release above — either let Flux reconcile them (if bootstrapped, see
#    infra/gitops/README.md) or apply them directly for local-only testing. Their
#    `dependsOn: [beekeepingit]` targets a HelmRelease *object* that only exists
#    once bootstrapped, so strip it for this direct-apply path (committed files
#    untouched) — step 4's install already guarantees what dependsOn was
#    protecting (the credential Secret/ConfigMap these reference are created
#    synchronously when the release's resources are applied, independent of
#    `--wait`):
for f in keycloak-helmrelease.yaml minio-helmrelease.yaml; do
  sed '/^  dependsOn:$/,+1d' "infra/gitops/apps/dev/$f" \
    | infra/cluster/with-lock.sh kubectl apply -f -
done

# 7. Wait for the PowerSync rollout (now unblocked by the schema-grants hook above)
kubectl -n beekeepingit-dev rollout status deployment/beekeepingit-powersync --timeout=180s

# 8. Wait for Keycloak/MinIO (see step 5's note on the pod-exists-first race), then
#    smoke-test the backing services (Postgres/PostGIS; #84). MinIO's vendored
#    chart predates the app.kubernetes.io/* label convention Keycloak's chart
#    follows — it only sets the legacy app=minio,release=<release-name> labels.
kubectl -n beekeepingit-dev wait --for=condition=ready pod -l app.kubernetes.io/instance=keycloak --timeout=300s
kubectl -n beekeepingit-dev wait --for=condition=ready pod -l app=minio,release=minio --timeout=180s
helm test beekeepingit --namespace beekeepingit-dev

# 9. Tear down
infra/cluster/with-lock.sh kubectl delete --ignore-not-found \
  -f infra/gitops/apps/dev/keycloak-helmrelease.yaml \
  -f infra/gitops/apps/dev/minio-helmrelease.yaml
infra/cluster/with-lock.sh helm uninstall beekeepingit --namespace beekeepingit-dev
infra/cluster/down.sh
```

## Verify the environment

Each of `#22`'s acceptance checks, in one place (all assume `dev-up.sh` finished successfully):

```sh
# PostGIS is enabled (helm test already runs this; shown here standalone)
kubectl -n beekeepingit-dev exec beekeepingit-postgres-1 -- \
  psql -U postgres -d beekeepingit -c "SELECT postgis_version();"

# Keycloak: seeded realm reachable through the gateway (add keycloak.beekeepingit.local
# to /etc/hosts pointing at 127.0.0.1, or use --resolve like this)
curl -sk --resolve keycloak.beekeepingit.local:8443:127.0.0.1 \
  https://keycloak.beekeepingit.local:8443/realms/beekeepingit/.well-known/openid-configuration

# MinIO: reachable via an S3-compatible client (health endpoint shown here; `mc`/`aws s3`
# work the same way once port-forwarded)
kubectl -n beekeepingit-dev port-forward svc/minio 9000:9000 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/minio/health/live

# PowerSync: pod healthy, replication + storage connected, no JWKS-fetch errors
kubectl -n beekeepingit-dev get pods -l app.kubernetes.io/name=powersync
kubectl -n beekeepingit-dev logs -l app.kubernetes.io/name=powersync --tail=50

# Gateway: routes to a backend service (Keycloak, today's only one — #23 adds more)
# — same curl as the Keycloak check above exercises this.
```

PowerSync's placeholder sync-config and Keycloak-JWKS stopgap are intentional local-dev
limitations (`#22`), not bugs — see `FOLLOWUPS.md` for what `#23`/`#106` still need to wire up.

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

This is a **local-dev-only** convention — it has no bearing on CI. Live-cluster CI does exist
(`.github/workflows/helm-e2e.yml`, `#154`, which even runs `up.sh`/`down.sh` themselves), but each
GitHub-hosted runner is a fresh, isolated machine that shares no filesystem with this one or with
other concurrent runs, so the `flock` serialization simply no-ops there — the lock protects the one
shared local cluster, and CI has no such shared resource to protect.

## Layout

| Path                                                         | What it is                                                                                                                                                 |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`cluster/`](cluster/)                                       | Local k8s cluster (k3d) bring-up (`up.sh`) and teardown (`down.sh`); whole-environment single-command bring-up/teardown (`dev-up.sh`/`dev-down.sh`, `#22`) |
| [`helm/beekeepingit/`](helm/beekeepingit/)                   | The Helm **umbrella chart** — see its own [README](helm/beekeepingit/README.md) for the subchart/values conventions                                        |
| [`helm/observability/`](helm/observability/)                 | The **observability stack** chart (#87) — its own Flux `HelmRelease`, deployed after MinIO; see its [README](helm/observability/README.md)                 |
| [`gitops/`](gitops/)                                         | **Flux** GitOps wiring that reconciles the charts onto the cluster from this repo — see its own [README](gitops/README.md)                                 |
| [`observability-smoke-test.sh`](observability-smoke-test.sh) | Fires a correlated trace+log+metric through the OTel Collector — a verification aid until `#23`'s services emit real telemetry                             |
| [`grafana-open.sh`](grafana-open.sh)                         | Dev convenience: fetches Grafana's admin password, port-forwards it, and opens the browser                                                                 |

Postgres+PostGIS, Keycloak, MinIO and the gateway (**#84**) are the umbrella chart's first real
subcharts. **PowerSync** (self-hosted Open Edition, [ADR-0005](../docs/adr/0005-sync-engine-choice.md))
lands with **#22** — see [`docs/architecture/walking-skeleton.md`](../docs/architecture/walking-skeleton.md)
§7.1 — with a placeholder sync-config and a Keycloak-JWKS stopgap until real domain tables and a
connector exist. The walking-skeleton services + PWA subcharts, plus PowerSync's real org-scoped
Sync Rules, land with **#23**/**#106**, wiring into this umbrella chart rather than standing up
their own release.

The **observability stack** (OTel Collector, Prometheus, Grafana, Loki, Tempo — `NFR-OBS-1`)
landed with **#87**: see
[`docs/architecture/platform.md#observability`](../docs/architecture/platform.md#observability)
for the design.
