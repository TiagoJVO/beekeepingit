# 0012 — Keycloak/MinIO as standalone Flux `HelmRelease`s, not nested in the umbrella chart

- **Status:** Accepted
- **Date:** 2026-07-05
- **Issue / Epic:** #84 (follow-up) · EPIC-13 (#83, #86) · **Milestone:** M0
- **Requirements:** NFR-ARC-2, NFR-ARC-3
- **Decisions:** [D-7](../../requirements/decisions.md) (Keycloak), [D-13](../../requirements/decisions.md) (Flux GitOps)
- **Supersedes:** the "wrapper chart nests the vendored dependency" approach for `keycloak`/`minio`
  in [ADR-0010](0010-platform-backing-services-provisioning.md) — everything else there
  (`postgres`/`gateway`/CNPG/Traefik/TLS) is unaffected.

## Context

ADR-0010 vendored `codecentric/keycloakx` and the official `charts.min.io` chart as **nested
dependencies** of thin wrapper charts (`infra/helm/beekeepingit/charts/keycloak/`, `.../minio/`),
themselves local `file://` dependencies of the umbrella chart. That works for local `helm install`
and CI's `helm lint`/`helm template` (both run `helm dependency build`, which recursively resolves
nested dependencies from any configured chart repo).

It does **not** work under Flux (`infra/gitops/`, #86/ADR-0009), which sources this chart straight
from a `GitRepository` — confirmed by direct test (a pristine checkout, no local `helm dependency
build` step, i.e. exactly what Flux's source-controller sees): `helm template` rendered the
wrapper charts' own Secret/ConfigMap but **zero** of the vendored chart's actual
`Deployment`/`StatefulSet`/`Service`. Reading source-controller's own dependency-resolution code
(`internal/helm/chart/{builder_local,dependency_manager}.go`) confirms why: it only resolves the
**top-level** chart's own immediate dependencies against what's already loaded from disk — it does
not recursively descend into a subchart's own separate `Chart.yaml` dependency list. A first fix
committed the resolved `.tgz` to git (an explicit `.gitignore` exception) to route around this —
it worked, but on reflection (and confirmed against Flux's own docs, which describe `HelmRepository`

- separate `HelmRelease` per chart as the pattern for consuming an upstream chart, not vendoring it
  into a git-sourced tree) that's a workaround, not the idiomatic answer, and it saddles the repo with
  binary blobs that go stale the moment `keycloakx`/`minio` bump versions.

## Decision

**Deploy Keycloak and MinIO as their own Flux `HelmRelease`s, sourced directly from their upstream
chart repos via a `HelmRepository` — not nested inside the umbrella chart at all.**

- New `infra/gitops/apps/dev/keycloak-helmrelease.yaml`: a `HelmRepository` (`codecentric`) +
  `HelmRelease` (`keycloak`), chart `keycloakx` v7.2.0, `dependsOn: [beekeepingit]`.
- New `infra/gitops/apps/dev/minio-helmrelease.yaml`: a `HelmRepository` (`minio`) + `HelmRelease`
  (`minio`), chart `minio` v5.4.0, `dependsOn: [beekeepingit]`.
- The umbrella chart's `charts/keycloak/`/`charts/minio/` subcharts **lose their nested
  dependency** entirely — they keep only what a vendored chart can't own itself: the generated
  admin-credential Secret + realm-import ConfigMap (keycloak), the generated root-credentials
  Secret (minio). The standalone `HelmRelease`s' `values:` reference these by a **literal** name
  (`extraEnv`/`existingSecret`) — there's no Helm templating inside a `HelmRelease`'s `values:`
  block, so this coupling is explicit, not implicit.
- **All three `HelmRelease`s pin `spec.releaseName`** (`beekeepingit`, `keycloak`, `minio`).
  Without it, Flux's helm-controller defaults the Helm release name to
  `<targetNamespace>-<HelmRelease name>` when they differ — confirmed against the live cluster,
  the umbrella release originally ran as `beekeepingit-dev-beekeepingit`, so its generated Secrets
  were `beekeepingit-dev-beekeepingit-keycloak-admin-credentials`, not the `beekeepingit-*` a
  plain `helm install beekeepingit` (or a local `helm template`) produces. Pinning makes all three
  names stable, predictable, and consistent between Flux and direct Helm — and keeps the literal
  cross-references above short (`beekeepingit-keycloak-admin-credentials`,
  `beekeepingit-keycloak-realm-import`). It also keeps the vendored charts' own generated resource
  names deterministic — e.g. the `gateway` subchart's backend `Service` reference is
  `keycloak-keycloakx-http` (confirmed via a standalone render), not the
  `beekeepingit-dev-keycloak-keycloakx-http` the default would produce. Pinning `releaseName` on
  an **already-installed** release is a one-time migration, not a hot edit (Helm won't adopt
  resources annotated with a different release name) — see the runbook below.
- `dependsOn: [beekeepingit]` on both new releases orders Flux's apply: the umbrella release
  (which creates those Secrets/ConfigMap) must be `Ready` before Keycloak/MinIO install, or
  `extraEnv`'s `secretKeyRef`/`existingSecret` would reference something that doesn't exist yet.
- The vendored `.tgz` files and the `.gitignore` exception from the first fix are removed; nothing
  is committed for either chart anymore. `helm-ci.yml` drops the `helm repo add`
  codecentric/minio steps — the umbrella's own `helm dependency build` is back to pure local
  `file://` resolution, no network involved.

## Consequences

**Positive**

- Matches Flux's own documented pattern (`HelmRepository` + `HelmRelease` per upstream chart)
  instead of routing around a limitation of the git-sourced umbrella chart.
- No binary blobs in git, no manual re-vendoring step to remember on every `keycloakx`/`minio`
  version bump — Flux's `HelmRepository` polls the real chart index and `chart.spec.version` is
  the only thing to bump.
- The umbrella chart is simpler and network-independent again (`helm dependency build` never
  touches an external chart repo), and `helm-ci.yml` sheds two steps.
- Makes the credential/config coupling between the umbrella's Secrets and the standalone releases
  **explicit** (a literal name in a `values:` block) rather than implicit (a Helm-templated
  `.Release.Name` inside a wrapper chart's own `values.yaml`) — easier to audit, if more verbose.

**Negative / risks**

- Two more top-level Flux objects to operate (`flux get helmreleases -A` now lists `beekeepingit`,
  `keycloak`, `minio` instead of one); `dependsOn` ordering is something to get right and keep
  right as the umbrella release's Secret/ConfigMap names change.
- A plain `helm install beekeepingit ...` (no Flux) **no longer deploys Keycloak or MinIO
  workloads** by itself — only their supplementary Secrets/ConfigMap. Getting them locally without
  full GitOps now means applying the two `HelmRelease`/`HelmRepository` manifests directly
  (`kubectl apply -f infra/gitops/apps/dev/keycloak-helmrelease.yaml -f
infra/gitops/apps/dev/minio-helmrelease.yaml`) — works because the Flux controllers (CRDs +
  helm-controller) are already installed on the dev cluster (ADR-0009), independent of the full
  `GitRepository`/`Kustomization` reconciliation chain; see `infra/README.md`.
- The literal-name coupling (keycloak's `extraEnv`/`extraVolumes` hardcode
  `beekeepingit-keycloak-*` Secret/ConfigMap names) is a real, if narrow, footgun: if the umbrella
  `HelmRelease`'s `releaseName` or `targetNamespace` ever changes, those references silently go
  stale. Mitigated by pinning all three release names (below) so the names are fixed by explicit
  config, not by Flux's defaulting behavior — but still a coupling to keep in mind when touching
  any of the three `HelmRelease`s.
- Pinning `releaseName` on the **already-running** umbrella release is a one-time migration with a
  brief window of downtime — Helm won't let a `beekeepingit` release adopt resources annotated for
  the old `beekeepingit-dev-beekeepingit` release, so the old release must be removed first. See
  the runbook below. (Data-wise this is a non-event at this stage: the postgres schemas are empty
  #84 scaffold with no tables yet, MinIO has no buckets, Keycloak is H2 + realm-import — everything
  is regenerated identically on reinstall.)

## Release-name migration runbook (one-time, at merge)

Because this pins `releaseName: beekeepingit` on a release that already exists on the `dev`
cluster under the Flux-defaulted name `beekeepingit-dev-beekeepingit`, a plain reconcile of this
change would fail with a Helm ownership conflict (the existing postgres `Cluster`, Secrets, etc.
are annotated `meta.helm.sh/release-name: beekeepingit-dev-beekeepingit`). Migrate once, right
after this lands on `main`:

```sh
# Stop Flux fighting the migration, remove the old-named release (deletes its
# resources — empty scaffold data at this stage, all regenerated below), then
# let Flux reinstall everything under the pinned names.
flux suspend helmrelease beekeepingit keycloak minio -n flux-system
infra/cluster/with-lock.sh helm uninstall keycloak minio -n beekeepingit-dev
infra/cluster/with-lock.sh helm uninstall beekeepingit-dev-beekeepingit -n beekeepingit-dev
flux resume helmrelease beekeepingit keycloak minio -n flux-system
flux reconcile helmrelease beekeepingit -n flux-system   # then keycloak/minio via dependsOn
```

After this, `helm list -n beekeepingit-dev` shows `beekeepingit`/`keycloak`/`minio`, and no
further migration is ever needed — the names are pinned.

## Alternatives considered

- **Commit the vendored `.tgz`** (the first fix, now reverted). Works, but not idiomatic per
  Flux's own guidance, and creates an ongoing manual-revendor maintenance burden with no tooling
  to catch staleness. Rejected on reflection.
- **Publish our own pre-built umbrella chart package** (resolve dependencies in CI, push to an OCI
  registry or chart repo, point Flux's `HelmRelease` at that artifact instead of `GitRepository`).
  A legitimate pattern for larger projects, but adds a publish step and a registry dependency for
  no benefit at this project's size — revisit if the umbrella chart grows more vendored
  dependencies than the two here.
- **Keep everything in one `HelmRelease`, add the vendored charts as umbrella dependencies
  directly** (no wrapper, no secrets). Rejected: still git-sourced (same underlying Flux
  limitation applies at the umbrella level itself, not just nested subcharts), and leaves nowhere
  to put the generated-credential Secret/realm ConfigMap.

## Follow-ups

- If `keycloakx`/`minio` need version bumps, only `infra/gitops/apps/dev/*-helmrelease.yaml`'s
  `chart.spec.version` changes — no local `helm dependency build`/re-vendor step exists anymore.
- EPIC-14 (#15): the literal Secret/ConfigMap name coupling should be revisited if multi-tenant
  per-org releases are introduced (the release names are pinned now, so a straight rename is no
  longer the risk — a per-org fan-out would be).
- **Merge-time:** run the release-name migration runbook above once, right after this lands on
  `main`, before Flux next reconciles the umbrella (or the reconcile fails on a Helm ownership
  conflict). Tracked in `FOLLOWUPS.md`.
