---
name: deploy-and-operate
description: >-
  How a BeekeepingIT change actually reaches a running environment, and how to verify it landed.
  Use when asked to release, deploy, promote, or validate something live; when someone asks "is
  this on staging yet?" or "why isn't my change live?"; when bringing a cluster up/down or
  pausing it; or when adding an external credential. Captures the rules that surprise everyone:
  a merge to `main` changes NOTHING on a live cluster — a release promotes the chart and the
  images together, and merging the promotion PR is the deploy; the chart is pinned by the
  GitRepository `ref` because Flux ignores `chart.spec.version` for git sources;
  `infra/helm/beekeepingit/environments/*.yaml` is a hand-synced MIRROR, not what runs (the
  deployed values live in the beekeepingit-gitops HelmRelease); GitHub environment secrets live
  on `staging-gate`/`production-gate`, not `staging`/`production`; and an authentik blueprint
  change has no restart wired anywhere, so it lands on an untimed delay and fails silently when
  it fails.
---

# Deploying & operating BeekeepingIT

Mechanics are documented in [`infra/README.md`](../../../infra/README.md) (bring-up, runbooks, the
Google-federation checklist) and [`docs/architecture/platform.md`](../../../docs/architecture/platform.md);
D-27/[ADR-0018](../../../docs/adr/0018-release-triggered-deploy-pipeline.md) owns the release design.
This skill is the map and the traps, not a restatement.

## Two repos — and the one that is the truth

- **`beekeepingit`** (this repo) holds the **charts** (`infra/helm/beekeepingit/`).
- **`TiagoJVO/beekeepingit-gitops`** holds the **Flux manifests _and the deployed values_** —
  `clusters/<env>/` (GitRepository + Kustomization + ClusterIssuer) and `apps/<env>/*.yaml`
  (the HelmReleases).

**`infra/helm/beekeepingit/environments/staging.yaml` is NOT what runs.** Its own header says it
mirrors the gitops HelmRelease's `values:` block by hand, for local `helm install` testing. Never
answer a "what is deployed?" question from it — read
`apps/<env>/beekeepingit-helmrelease.yaml` in the gitops repo:

```sh
gh api repos/TiagoJVO/beekeepingit-gitops/contents/apps/staging/beekeepingit-helmrelease.yaml \
  --jq '.content' | base64 -d
```

That drift is not theoretical: **#556** is a live cert-renewal outage caused by exactly it — the
gitops HelmRelease never got `gateway.adminHost`/`global.adminOrigin`, so the chart's dev default
`admin.beekeepingit.local` leaked into staging's ACME order and renewal has failed 24 times.

## A merge to `main` changes nothing on a live cluster

**Merging the promotion PR is the deploy.** A release promotes as one artifact — both the image
tags in `apps/<env>/beekeepingit-helmrelease.yaml` **and** the `beekeepingit` `GitRepository`'s
`ref` in `clusters/<env>/flux-system.yaml`, so the chart comes from the release too. Reverting that
merge rolls both back together.

Two mechanics worth knowing, because they are the reason it is pinned that way:

- **The `ref` is the only pin there is.** Flux ignores `chart.spec.version` for a `GitRepository`
  source ("applicable only when the Source reference is a `HelmRepository`"), so chart content is
  whatever revision the source resolves to — nothing else constrains it.
- **`reconcileStrategy` must stay `Revision`.** `ChartVersion` keys on `Chart.yaml`'s `version`,
  frozen at `0.1.0` and never bumped, so a pinned-tag release would never deploy at all.

> **History worth knowing, because it explains stale docs and any un-migrated environment:** until
> 2026-08-31 every environment's chart source read `ref: branch: main`, so merging re-rendered
> templates, NetworkPolicies and the Authentik blueprint onto the live cluster within ~1–6 minutes,
> ungated — images were pinned, the chart was not (ADR-0018 addendum; ADR-0009 had called for a
> release ref all along). If an environment still shows `branch: main` under
> `flux get sources git -A`, it predates that fix.

**Decision — does your change reach an environment?**

| Change                                                              | How it ships                                     |
| ------------------------------------------------------------------- | ------------------------------------------------ |
| Go service, Flutter client, or admin app code                       | Release → images                                 |
| Chart templates/values, authentik blueprint, NetworkPolicy, Ingress | Release → chart (the pinned `ref` moves with it) |
| Docs, CI scripts, tests                                             | Never deploys                                    |

`dev` is the exception and deliberately so: it has no release to pin to and tracks `main`, which is
what makes it the post-merge integration environment.

## Cutting a release (when images actually changed)

Manual steps are marked — nothing auto-deploys from a merge.

1. **[you]** Publish a GitHub Release on a `main` commit. **The tag routes it**: `*-rc*` →
   staging (gate `staging-gate`, unprotected, runs immediately); anything else → prod (gate
   `production-gate`, required reviewer). Do not cut a bare tag — D-26 keeps deployments
   staging-grade until `Q-DR` and #90 land.
2. **[auto]** `release-deploy.yml` builds every Go service + the PWA + admin, Trivy-scans
   (HIGH/CRITICAL blocks the push even after approval), pushes to ghcr tagged with the release
   tag, then opens a **promotion PR against the gitops repo** bumping the image tags _and_ the
   chart `ref`.
3. **[you]** Merge that PR. **This is the actual deploy decision** — the PAT cannot merge it.
4. **[auto]** Flux reconciles by **polling** (no webhooks). Force it with
   `flux reconcile helmrelease beekeepingit -n flux-system --force`.

**Rollback = `git revert` the promotion PR** in the gitops repo — which now takes the chart back
with the images, rather than leaving it on whatever `main` had drifted to. Manual `kubectl`/`helm`
edits to anything Flux owns are reverted on the next reconcile (`prune: true`).

The PWA and admin bake their URLs in at **build time** (Dart `--dart-define`, Vite `VITE_*`), so
one image cannot serve two environments — the release target picks them.
`scripts/check-deploy-url-drift.sh` (in `task ci`) fails if those disagree with
`environments/<env>.yaml`.

## Authentik blueprint changes need a nudge, and fail silently

The umbrella chart renders the blueprint into ConfigMap `beekeepingit-authentik-blueprint`, but
**authentik is a separate HelmRelease** that only references it by name. Consequence, verified by
grep across the gitops repo: **no `checksum/config` annotation, no reloader, no `rollout restart`
anywhere.** Changing the ConfigMap does not re-render or restart authentik — pickup depends on
kubelet volume refresh plus authentik's own periodic discovery, i.e. **eventual and untimed**.

Force it, then **verify it applied** — do not infer success from the login page:

```sh
kubectl -n beekeepingit-staging rollout restart deploy/authentik-worker
kubectl -n beekeepingit-staging exec deploy/authentik-worker -- ak shell -c \
  "from authentik.blueprints.models import BlueprintInstance; [print(i.path, '|', i.status, '|', i.last_applied) for i in BlueprintInstance.objects.all()]"
```

Two silent failure shapes, both of which look like "the feature just isn't there":

- **One invalid entry invalidates the whole file** — nothing in it applies, the apply task still
  finishes with `exc:null`, and the only outward symptom is **OIDC discovery 404ing forever**
  (the PR #414 shape). Evidence lives only on the `BlueprintInstance` row.
- **`!Env [VAR]` (one element) raises `IndexError` at parse time**, killing discovery for the
  entire file so **no `BlueprintInstance` row is created at all**. Always
  `!Env [VAR, ""]`. A structural YAML parse does not catch this — the tag constructors only run
  inside authentik. `scripts/check-federation-source-posture.sh` pins it offline.

## Credentials

In-cluster secrets (Postgres, authentik keys, MinIO root, Grafana admin) **generate themselves**
via the chart's `lookup` + `randAlphaNum` idiom. Only external credentials come from GitHub.

**They live on the `staging-gate` / `production-gate` environments, not `staging`/`production`** —
`cluster-ops.yml` maps env → gate and the job runs under the gate. Putting them on `staging`
fails **silently**: the script takes its "not set — skipping" path and the workflow still goes
green. Verify what exists rather than assuming:

```sh
gh api repos/TiagoJVO/beekeepingit/environments/staging-gate/secrets --jq '.secrets[].name'
```

Provisioning is `cluster-ops` (`workflow_dispatch`, action `up`) — idempotent, so it is also the
rotation path. Prefer it to a hand-made `kubectl create secret`, which the next rebuild drops.

**The `lookup` two-pass trap:** Helm's `lookup` returns empty on the render where the Secret did
not yet exist, so after creating one you must force a **second** render
(`flux reconcile helmrelease beekeepingit -n flux-system --force`).

Adding a new external credential is **four coordinated edits** and
[`infra/README.md`](../../../infra/README.md) documents them because **three fail silently**: the
`scaleway-up.sh` block, the `cluster-ops.yml` `env:`, `.env.example`, and the docs table.

## Clusters: which script destroys data

| Script                   | Effect                                        | Data     |
| ------------------------ | --------------------------------------------- | -------- |
| `scaleway-up.sh`         | create/reconcile + GitOps bootstrap           | n/a      |
| `scaleway-scale-down.sh` | delete the node pool; control plane stays     | **kept** |
| `scaleway-scale-up.sh`   | recreate the pool; never creates a cluster    | **kept** |
| `scaleway-down.sh`       | **destroys** cluster, volumes, load balancers | **LOST** |

Pause/resume is `scale-down`/`scale-up` ([ADR-0022](../../../docs/adr/0022-durable-storage-pause-resume-not-volume-reattach.md)) —
`down` is not "stop for the day". Data survives scale-down because nothing detaches from the
cluster's object model, only from compute; CNPG's `bootstrap.initdb` would **re-initialize an
empty PGDATA** rather than adopt an existing one, so a destroyed cluster cannot simply be
re-pointed at its old volumes.

Locally, `dev-up.sh` deliberately does **not** bootstrap GitOps (that would deploy from `main`,
defeating a pre-merge loop). Use `with-lock.sh` for any cluster-mutating command — the lock is
keyed by cluster name, so every worktree shares it.

## Known gaps (verified 2026-08-31 — re-check before relying on these)

- **Nothing carries `suspend: true`.** Prod is inert purely because no cluster has been
  bootstrapped against `clusters/prod/`; the instant one is, Flux deploys whatever those manifests
  say — today `v0.0.0` placeholder image tags and `.example` hostnames, with
  `networkpolicy.gatewayNamespace` left at the `kube-system` default that
  [ADR-0017](../../../docs/adr/0017-scaleway-cloud-hosting.md) records as silently blocking every
  gateway→backend edge on Kapsule.
- **`flux get sources git -A` is the check that an environment is actually pinned.** Anything
  still showing `branch: main` for the `beekeepingit` source predates the 2026-08-31 fix and is
  taking its chart from `main`. That is the live-side check; on the Git side the gitops repo's
  `chart-pin` CI job (`scripts/check-chart-pin.sh`, #611) fails any PR that un-pins staging/prod or
  repoints the umbrella HelmRelease at an unpinned source.
- **Flux reports "reconciled" without health.** Every umbrella HelmRelease sets
  `disableWait: true` (a real fix — Helm's wait deadlocks against the `schema-grants` post-install
  hook) and no Kustomization has `healthChecks`, so `dependsOn` orders _application_, not
  _readiness_.
- **`notify-deploy` over-reports.** It fires on any change to the staging/prod HelmRelease file
  and posts `state: success` without observing Flux — a values-only edit records a "deploy".
- **dev declares 4 of the 7 services**, so it silently falls back to chart defaults for
  `activities`/`journeys`/`todos`.
