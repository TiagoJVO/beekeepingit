# 0022 — Durable remote-cluster storage: pause/resume the node pool, not delete-and-reattach volumes

- **Status:** Accepted
- **Date:** 2026-08-22
- **Requirements:** NFR-DR-1, NFR-ARC-2
- **Decisions:** [D-26](../../requirements/decisions.md) (Scaleway Kapsule hosting), builds on
  [ADR-0017](0017-scaleway-cloud-hosting.md) (staging stood up first)
- **Design:** [`infra/README.md`](../../infra/README.md#pausing-and-resuming-an-environment-without-losing-data-539),
  `infra/cluster/scaleway-scale-{down,up}.sh`, `infra/cluster/scw-common.sh`,
  `infra/cluster/scw-cluster-prereqs.sh`

## Context

`scaleway-down.sh` deletes the whole Kapsule cluster with `with-additional-resources=true`, which
also deletes its block-storage volumes and Load Balancers. `scaleway-up.sh` then always bootstraps
from empty. Routine "stop paying for compute between sessions" teardown was therefore
indistinguishable from actually destroying the environment — every down/up cycle lost Postgres,
Authentik, and MinIO's data (#539).

The issue as filed assumed the fix was: keep `down` deleting the cluster, but leave the
CSI-provisioned block volumes behind as orphaned cloud resources (tagged for identification), then
have `up` recreate `PersistentVolume`/`PersistentVolumeClaim` objects pointing at those surviving
volumes so the same data reattaches to a brand-new cluster.

That assumption didn't survive research. CloudNativePG's `bootstrap.initdb` — how the `postgres`
subchart's `Cluster` CR is bootstrapped — unconditionally initializes a **fresh, empty** PGDATA on
whatever PVC it's given; it renames aside (does not destroy) a pre-existing valid PGDATA rather than
adopting it, and CNPG's own maintainers confirm there is no flag to skip this
(cloudnative-pg/cloudnative-pg#2250). The only maintainer-endorsed way to start a CNPG cluster from
prior data is `bootstrap.recovery` (a `VolumeSnapshot`, a `Backup` object, or a Barman object
store) — none of which is a bare static-PVC reattachment, and all of which are recovery/backup
machinery the issue explicitly scoped out ("this is deliberately not backups... stays with #92 /
Q-DR"). Building the assumed design would have meant either quietly reimplementing a slice of #92,
or accepting that CNPG Postgres — the database holding organization/apiary/activity data — was the
one component the "keep storage" feature didn't actually keep.

## Decision

**Don't delete the cluster on routine teardown at all.** Scaleway's Kapsule control plane is free on
the default "Mutualized" tier, independent of node count, and a Kubernetes cluster's
`PersistentVolumeClaim`/`PersistentVolume`/custom-resource objects live in etcd — part of the
control plane, not the worker nodes. So instead of deleting the whole cluster and later trying to
resurrect its data from raw cloud volumes, `scaleway-scale-down.sh` scales the node pool to **0**
and leaves the cluster running. Nothing is ever detached from the Kubernetes object model — only
from compute — so there is no reattachment problem to solve, no CNPG bootstrap-mode question, no
volume tagging/identification scheme, and no static PV/PVC authoring. `scaleway-scale-up.sh` scales
the pool back up; every pod (including CNPG's) reschedules and reattaches its still-`Bound` PVC
through ordinary Kubernetes CSI semantics, and cluster-scoped prerequisites that lived on the
deleted nodes (CNPG operator, Traefik, cert-manager, Flux) are reinstalled via the same idempotent
calls `scaleway-up.sh` already made on first bring-up (factored into `scw-cluster-prereqs.sh` so the
two callers can't drift).

`scaleway-up.sh`/`scaleway-down.sh` are **unchanged** — they remain the full create/destroy pair for
when an environment should genuinely be thrown away or built from nothing. The new scripts are
purely additive; nothing that already worked was touched beyond extracting a shared
credentials/lock preamble (`scw-common.sh`) that all four scripts now use identically, and the
shared cluster-prerequisite installer both `up`/`scale-up` now call, to avoid re-duplicating that
logic a third and fourth time (rather than adding mode flags to the existing two scripts).

The Load Balancer is deleted via `kubectl delete svc` (the LoadBalancer-type Service), not a direct
`scw lb lb delete` call — deleting the cloud resource directly out from under a Service the
cloud-controller-manager still believes it owns risks leaving the CCM with a stale reference;
deleting the Service lets the CCM deprovision through its own reconciliation loop, and `scale-up`
recreates it (and therefore a fresh LB) by reinstalling Traefik.

## Consequences

- Routine teardown/bring-up (`scale-down`/`scale-up`) no longer touches CNPG's bootstrap mode, CSI
  volume-snapshot support, or any Scaleway-side volume tagging/discovery scheme at all — the entire
  class of "hard parts" the original issue flagged for a spike doesn't apply to this design.
- `scale-down` does not require `cluster-ops.yml`'s type-the-cluster-name `confirm` input the way
  `down` does: it destroys nothing, so the same typo-guard bar as an irreversible deletion isn't
  warranted. It still runs behind the same staging-gate/production-gate approval as every other
  action.
- Two things this design leans on are **not independently documented by Scaleway** and are flagged,
  not silently assumed: (1) the free-control-plane claim only holds on the Mutualized tier, not a
  paid Dedicated one — worth a one-time `scw k8s cluster get` check per cluster; (2) there's no
  stated Scaleway policy on reaping long-idle zero-node clusters, so `scale-down` isn't recommended
  for multi-week/-month pauses without checking directly — `scaleway-down.sh` remains the
  better-understood choice at that horizon.
- The issue's original acceptance criteria (written around full cluster deletion + volume
  reattachment + tagging) were revised to match this design; see #539.

## Alternatives considered

- **Full cluster deletion + static PV/PVC reattachment on `up`** (the issue's original framing).
  Rejected: doesn't work for CNPG Postgres without routing through `bootstrap.recovery`
  (VolumeSnapshots/Backup/Barman) — recovery/backup machinery the issue explicitly excluded — and
  even for Authentik/MinIO (plain StatefulSets, where static reattachment would work) it requires a
  self-maintained volume tagging/discovery scheme, since Scaleway's CSI driver applies no default
  tags tying a volume back to its originating PVC.
- **CNPG hibernation** (`cnpg.io/hibernation` annotation). Doesn't apply here: it's a
  same-cluster/same-namespace mechanism for keeping PVCs while scaling an instance's replicas to
  zero — it has nothing to reattach to once the whole cluster (etcd included) is deleted, which is
  exactly the scenario this decision avoids by not deleting the cluster in the first place.
- **Deleting the node pool object entirely** (`scw k8s pool delete`) instead of scaling it to 0.
  Rejected: Scaleway requires a cluster to keep at least one pool; scaling the existing pool's
  `size` to 0 satisfies that constraint while achieving the same "zero billed compute" outcome.
