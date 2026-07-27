# 0009 — GitOps: Flux, hand-wired (not `flux bootstrap`)

- **Status:** Accepted
- **Date:** 2026-07-04
- **Issue / Epic:** #86 · EPIC-13 · **Milestone:** M0
- **Requirements:** NFR-ARC-3, NFR-MNT-1
- **Decisions:** [D-13](../../requirements/decisions.md#d-13--gitops-flux-hand-wired-not-flux-bootstrap),
  builds on [D-1](../../requirements/decisions.md) (single cluster)
- **Design:** the [`beekeepingit-gitops`](https://github.com/TiagoJVO/beekeepingit-gitops) repo's
  README (layout, operating it — the manifests moved there per D-27/ADR-0018; Flux + hand-wired,
  this ADR's decision, is unchanged) · [platform.md](../architecture/platform.md) (as-built overview)

## Context

`EPIC-13`/#83 landed the k8s cluster and the Helm umbrella chart
(`infra/helm/beekeepingit/`), deployed today by a human running `helm install`/`upgrade`. #86
asks for GitOps: the desired state should live in Git, a manual `kubectl`/`helm` change should be
reverted, a merge to the tracked branch should auto-deploy, sync/health should be observable, and
rollback should be a Git operation. `requirements/tech-stack.md` had left the GitOps tool as
"ArgoCD/Flux optional" — undecided.

Two questions needed answering: **which controller**, and **how is it wired up** (since wiring a
GitOps controller to a repo is itself either a one-time imperative bootstrap or a scripted one).

## Decision

### 1. Flux, not ArgoCD

Flux v2 controllers (`source-controller`, `kustomize-controller`, `helm-controller`,
`notification-controller`) were already installed on the dev cluster (`flux install`) as part of
earlier cluster setup, though not yet bootstrapped against this repo. Adopting Flux is the path
of least resistance — no new tool to stand up, and it directly supports reconciling a Helm chart
via its native `HelmRelease` CRD (`helm.toolkit.fluxcd.io`), which is exactly the umbrella-chart
shape already in place. ArgoCD would add a second controller and a UI neither required by the
acceptance criteria nor justified for a single local dev cluster at this stage.

### 2. Hand-wired manifests + one-time `kubectl apply`, not `flux bootstrap github`

`flux bootstrap github` is the conventional way to wire Flux to a GitHub repo, but it:

- creates a deploy key (or uses a PAT) via the GitHub API, and
- **commits directly to the target branch**, bypassing pull requests entirely.

That conflicts with `CONTRIBUTING.md`'s GitHub-Flow (branch → PR → CI → squash-merge to `main`).
Instead:

- The Flux objects (`GitRepository`, `Kustomization`, `HelmRelease`) are **plain YAML committed
  like any other change** — reviewed in a PR the same as Helm chart changes.
- **Bootstrapping** the cluster onto them is one `kubectl apply -f infra/gitops/clusters/dev/`,
  run once after merge (documented in `infra/gitops/README.md`, mirroring `infra/README.md`'s
  existing manual Quickstart pattern). No deploy key or PAT is created — the repo is **public**,
  so the `GitRepository` pulls over anonymous HTTPS.
- After that one apply, the `clusters/dev/` directory is **self-referential**: its own
  `Kustomization` has `path: ./infra/gitops/clusters/dev`, so future changes to the bootstrap
  objects themselves also reconcile from Git without a second manual step (only a schema-breaking
  change, e.g. renaming the `GitRepository`, would need a re-apply).

### 3. Polling, not webhooks

`GitRepository.spec.interval` (1m) is the only trigger — there's no GitHub webhook receiver
because the local k3d cluster has no public endpoint for GitHub to reach. `flux reconcile ...
--with-source` is available for an immediate sync when polling latency matters (e.g. during
manual verification).

## Consequences

- Merges to `main` deploy within the poll interval, no manual `helm upgrade` needed for the
  umbrella chart going forward — `infra/README.md`'s manual quickstart commands remain useful for
  bring-up/local iteration on a chart change **before** it's merged, but are no longer how `dev`
  gets updated once merged.
- A manual `kubectl`/`helm` change to anything Flux owns (the `beekeepingit` release, or the
  bootstrap objects) is reverted on the next reconcile (`prune: true`) — this is a deliberate
  trade-off: no more ad hoc `kubectl edit` on cluster resources; changes go through Git.
- Rollback is `git revert` on `main`, not a cluster-side action.
- Extending to `staging`/`prod` later means adding `clusters/staging/`, `clusters/prod/` (own
  `GitRepository`, likely pointing at a release branch/tag rather than `main`) and matching
  `apps/staging/`, `apps/prod/` `HelmRelease`s — mirrors the existing (currently unused)
  `environments/{staging,prod}.yaml` Helm overlays.
- The Flux **controller installation** itself (`flux install`) stays imperative/untracked — only
  the _application_ reconciliation is GitOps-managed. Self-managing the controllers too (the
  `flux-system/gotk-components.yaml` pattern `flux bootstrap` would normally generate) is not
  needed at this stage and can be added later without disrupting this layout.

## Alternatives considered

- **ArgoCD** — rejected: would duplicate what Flux already does for a Helm-chart-shaped
  deployment, and adds a UI/controller not needed for a single local cluster (`NFR-ARC-3` doesn't
  ask for a GitOps dashboard).
- **`flux bootstrap github`** — rejected: pushes directly to `main`, bypassing PR review; also
  creates a GitHub deploy key/PAT dependency this public, single-maintainer repo doesn't need.
- **GitHub webhook → Flux receiver** — deferred: would need a public ingress endpoint into the
  local dev cluster; polling is sufficient for the stated acceptance criteria (no latency
  requirement on sync).

## Follow-ups

- #88 (CI/CD) will add CI-driven image publish + manifest update; this ADR only covers the
  controller + reconciliation half per #86's own scope note.
