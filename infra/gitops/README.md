# GitOps (Flux)

Flux reconciles the Helm umbrella chart ([`infra/helm/beekeepingit/`](../helm/beekeepingit/))
onto the local cluster from this repo (`NFR-ARC-3`, `NFR-MNT-1`, `D-13`), replacing manual
`helm install`/`upgrade`. See [`docs/architecture/platform.md`](../../docs/architecture/platform.md)
for the as-built design and [ADR-0008](../../docs/adr/0008-gitops-flux.md) for why Flux, and why
hand-wired instead of `flux bootstrap`.

## Prerequisites

The Flux controllers themselves are installed **imperatively**, not tracked in Git (this repo's
GitOps scope is the *application* reconciliation, not self-managing the Flux install):

```sh
flux install   # installs the flux-system namespace + controllers; idempotent
flux check     # verify
```

## Layout

| Path | What it is |
|---|---|
| [`clusters/dev/flux-system.yaml`](clusters/dev/flux-system.yaml) | `GitRepository` (this repo, `main`) + the self-referential `Kustomization` that keeps everything under `clusters/dev/` (including itself) reconciled from Git |
| [`clusters/dev/apps.yaml`](clusters/dev/apps.yaml) | `Kustomization` pointing Flux at `apps/dev/` |
| [`apps/dev/beekeepingit-helmrelease.yaml`](apps/dev/beekeepingit-helmrelease.yaml) | `HelmRelease` deploying the umbrella chart into `beekeepingit-dev`, mirroring `environments/dev.yaml` |

Adding `staging`/`prod` later means adding `clusters/staging/`, `clusters/prod/` (own
`GitRepository`/bootstrap `Kustomization`, likely pointing at a release branch/tag instead of
`main`) and `apps/staging/`, `apps/prod/` `HelmRelease`s — mirroring how
`environments/{staging,prod}.yaml` already exist as unused overlays on the Helm chart.

## One-time bootstrap

Once this is merged to `main`, wire the cluster to track it (idempotent — safe to re-run):

```sh
kubectl apply -f infra/gitops/clusters/dev/
```

After that, everything under `infra/gitops/` — including `clusters/dev/flux-system.yaml` itself —
is reconciled from Git automatically; no further manual `kubectl`/`helm` is needed for app
changes. Only re-run the command above if the *bootstrap* objects change in a way Flux can't
reconcile on its own (e.g. renaming the `GitRepository`).

## Operating it

```sh
flux get sources git              # GitRepository fetch status
flux get kustomizations -A        # sync + health per Kustomization
flux get helmreleases -A          # sync + health per HelmRelease (this is the umbrella chart)
flux reconcile kustomization beekeepingit-dev --with-source   # force an immediate sync
```

Reconciliation is **polling-only** (no GitHub webhook receiver) since the local cluster has no
public endpoint for GitHub to call — see ADR-0008. A merge to `main` is picked up within the
`GitRepository`'s 1-minute poll interval; use `flux reconcile ... --with-source` to not wait.

Drift (a manual `kubectl`/`helm` change) is reverted on the next reconcile (`spec.prune: true` +
Helm's own drift detection). Rolling back is a Git operation — `git revert` the offending commit
on `main`; Flux applies the reverted state on its next reconcile.
