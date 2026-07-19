# GitOps (Flux)

Flux reconciles the Helm umbrella chart ([`infra/helm/beekeepingit/`](../helm/beekeepingit/))
onto the local cluster from this repo (`NFR-ARC-3`, `NFR-MNT-1`, `D-13`), replacing manual
`helm install`/`upgrade`. See [`docs/architecture/platform.md`](../../docs/architecture/platform.md)
for the as-built design and [ADR-0009](../../docs/adr/0009-gitops-flux.md) for why Flux, and why
hand-wired instead of `flux bootstrap`.

## Prerequisites

The Flux controllers themselves are installed **imperatively**, not tracked in Git (this repo's
GitOps scope is the _application_ reconciliation, not self-managing the Flux install):

```sh
# Base controllers only. Flux is read-only here — it reconciles from Git, it does not
# write to it (D-27/ADR-0018 replaced image-automation, so the image-reflector/
# image-automation controllers are no longer installed).
flux install
flux check     # verify
```

## Layout

| Path                                                                                 | What it is                                                                                                                                                      |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`clusters/dev/flux-system.yaml`](clusters/dev/flux-system.yaml)                     | `GitRepository` (this repo, `main`) + the self-referential `Kustomization` that keeps everything under `clusters/dev/` (including itself) reconciled from Git   |
| [`clusters/dev/apps.yaml`](clusters/dev/apps.yaml)                                   | `Kustomization` pointing Flux at `apps/dev/`                                                                                                                    |
| [`apps/dev/beekeepingit-helmrelease.yaml`](apps/dev/beekeepingit-helmrelease.yaml)   | `HelmRelease` deploying the umbrella chart into `beekeepingit-dev`, mirroring `environments/dev.yaml`                                                           |
| [`apps/dev/authentik-helmrelease.yaml`](apps/dev/authentik-helmrelease.yaml)         | `HelmRepository` (authentik) + `HelmRelease` deploying Authentik (bundled Postgres, no Redis) directly, not nested in the umbrella chart, see ADR-0012/ADR-0016 |
| [`apps/dev/minio-helmrelease.yaml`](apps/dev/minio-helmrelease.yaml)                 | `HelmRepository` (minio) + `HelmRelease` deploying MinIO directly, same reasoning, ADR-0012                                                                     |
| [`apps/dev/observability-helmrelease.yaml`](apps/dev/observability-helmrelease.yaml) | `HelmRelease` deploying the observability chart (`infra/helm/observability`, #87) after MinIO (`dependsOn`) — see ADR-0013                                      |

`staging` and `prod` now exist as their own `clusters/{staging,prod}/` + `apps/{staging,prod}/`
trees, mirroring `dev`. Under D-27 ([ADR-0018](../../docs/adr/0018-release-triggered-deploy-pipeline.md))
this whole `infra/gitops/` tree moves to a separate `beekeepingit-gitops` repo; the Helm chart stays
in this repo and Flux sources the two independently. Until that split lands, everything is reconciled
from this repo as described above.

### Why Authentik/MinIO are separate `HelmRelease`s, not umbrella subcharts

The umbrella chart is sourced by Flux straight from this `GitRepository` — its source-controller
only resolves the umbrella's own top-level dependencies from what's checked into Git; it does not
recursively `helm dependency build` into a subchart's own nested vendored dependency (verified
directly: a pristine checkout without one, once vendored inline, rendered zero of that vendored
chart's actual resources, silently). Authentik (authentik/authentik) and MinIO (charts.min.io)
are consumed instead the way Flux's own docs describe: a `HelmRepository` + `HelmRelease` per
upstream chart, with `dependsOn: [beekeepingit]` so the umbrella release's generated credential
Secrets + Authentik blueprint ConfigMap exist first. See
[ADR-0012](../../docs/adr/0012-keycloak-minio-standalone-helmreleases.md) for the full reasoning
(and [ADR-0016](../../docs/adr/0016-replace-keycloak-with-authentik.md) for the Keycloak→Authentik
swap; [ADR-0010](../../docs/adr/0010-platform-backing-services-provisioning.md) for what ADR-0012
supersedes).

## One-time bootstrap

Once this is merged to `main`, wire the cluster to track it (idempotent — safe to re-run):

```sh
kubectl apply -f infra/gitops/clusters/dev/
```

After that, everything under `infra/gitops/` — including `clusters/dev/flux-system.yaml` itself —
is reconciled from Git automatically; no further manual `kubectl`/`helm` is needed for app
changes. Only re-run the command above if the _bootstrap_ objects change in a way Flux can't
reconcile on its own (e.g. renaming the `GitRepository`).

## Operating it

```sh
flux get sources git              # GitRepository fetch status
flux get kustomizations -A        # sync + health per Kustomization
flux get helmreleases -A          # sync + health per HelmRelease (this is the umbrella chart)
flux reconcile kustomization beekeepingit-dev --with-source   # force an immediate sync
```

Reconciliation is **polling-only** (no GitHub webhook receiver) since the local cluster has no
public endpoint for GitHub to call — see ADR-0009. A merge to `main` is picked up within the
`GitRepository`'s 1-minute poll interval; use `flux reconcile ... --with-source` to not wait.

Drift (a manual `kubectl`/`helm` change) is reverted on the next reconcile (`spec.prune: true` +
Helm's own drift detection). Rolling back is a Git operation — `git revert` the offending commit
on `main`; Flux applies the reverted state on its next reconcile.
