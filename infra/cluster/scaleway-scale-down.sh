#!/usr/bin/env bash
# Pause a Scaleway Kapsule environment (#539, D-26) — staging by default, prod
# via BK_CLUSTER_ENV=prod. Stops paying for compute WITHOUT losing anything:
# scales the node pool to 0 so the cluster's control plane (free on Kapsule's
# Mutualized tier, independent of node count — see infra/README.md) keeps
# running with etcd intact, which means every PersistentVolumeClaim, the CNPG
# `Cluster` custom resource, and Flux's own state never leave the Kubernetes
# API — there is nothing to "reattach" later, because nothing was ever
# detached from the cluster's object model, only from its compute. Undo with
# scaleway-scale-up.sh.
#
# This is NOT scaleway-down.sh. That script permanently destroys the cluster,
# its volumes, and its Load Balancers — use it when you actually want to
# throw the environment away. This script is for the routine "stop the meter
# between sessions" case and is safe to run often.
#
# What it does, in order:
#   1. Delete every LoadBalancer-type Service (there's normally just one,
#      Traefik's) so Scaleway's cloud-controller-manager cleanly deprovisions
#      the billed Load Balancer(s) behind them through its own reconciliation
#      — deleting the LB directly via the Scaleway API instead, out from
#      under a Service the CCM still believes it owns, risks leaving the CCM
#      with a stale reference. scaleway-scale-up.sh recreates the Service (and
#      therefore a fresh LB) by re-running the same `helm upgrade --install
#      traefik` scaleway-up.sh already does on first bring-up.
#   2. Cordon + drain every node (Scaleway's own documented safe-scale-down
#      sequence — see infra/README.md), so workloads shut down cleanly instead
#      of being yanked.
#   3. Scale every node pool on the cluster to 0.
#
# Credentials/env come from the same place as scaleway-up.sh/-down.sh: a
# `scw init` profile, or SCW_ACCESS_KEY/SCW_SECRET_KEY/... env vars — locally
# via infra/cluster/.env (see .env.example), in CI via GitHub secrets.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/cluster/scw-common.sh
. "$script_dir/scw-common.sh"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: 'kubectl' not found on PATH" >&2
  exit 1
fi

cluster_id="$(scw k8s cluster list name="$cluster_name" region="$region" -o template='{{ .ID }}' 2>/dev/null || true)"
if [ -z "$cluster_id" ]; then
  echo "cluster '$cluster_name' does not exist in $region — nothing to scale down"
  exit 0
fi

# The control plane answers regardless of node count, so kubectl works here
# even if a previous scale-down already left this cluster at 0 nodes
# (idempotent — re-running this script is safe).
scw k8s kubeconfig install "$cluster_id" region="$region"
echo "active kubectl context: $(kubectl config current-context)"

# 1. Delete LoadBalancer-type Services first, while nodes still exist to run
# the CCM's controller pod that actually talks to the Scaleway LB API.
#
# No `2>/dev/null || true` on this (or the node/pool lookups below): this
# script's whole purpose is a cost-safety mechanism, so a transient kubectl/scw
# failure must abort loudly (set -e does exactly that) rather than being
# swallowed into "found nothing" and silently skipping the corresponding
# action while the closing summary still claims success.
echo "looking for LoadBalancer-type Services to delete"
lb_svcs="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}')"
if [ -z "$lb_svcs" ]; then
  echo "no LoadBalancer-type Services found — nothing to delete"
else
  echo "Services to delete:"
  while IFS= read -r svc; do
    [ -n "$svc" ] && echo "  $svc"
  done <<<"$lb_svcs"
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    ns="${svc%%/*}"
    name="${svc#*/}"
    echo "deleting Service $svc (blocks until its Load Balancer finishes deprovisioning)"
    kubectl -n "$ns" delete svc "$name" --timeout=300s
  done <<<"$lb_svcs"
fi

# 2. Cordon + drain every node before scaling pools to 0, rather than
# yanking nodes out from under running pods. --disable-eviction: CNPG
# creates a PodDisruptionBudget on its (single-instance, no-HA) Postgres
# pod specifically to block eviction when there's no replica to fail
# over to — correct for rolling maintenance on a live multi-node
# cluster, but meaningless here, since we're about to scale every node
# to 0 anyway and there is no "elsewhere" for the pod to go regardless.
# --disable-eviction bypasses that PDB admission check by deleting the
# pod directly instead of going through the Eviction API — it still
# sends a graceful SIGTERM and honors terminationGracePeriodSeconds
# (kubectl delete, not --force), so Postgres still gets a clean
# shutdown; only the "wait for a safe moment" logic is skipped, and
# there is no safe moment to wait for here (confirmed live: the plain
# eviction path spins for the full default 5m timeout against
# beekeepingit-postgres-1's PDB and then hard-fails, #539).
nodes="$(kubectl get nodes -o name)"
if [ -n "$nodes" ]; then
  echo "cordoning and draining nodes"
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    kubectl cordon "$node"
  done <<<"$nodes"
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --disable-eviction --timeout=300s
  done <<<"$nodes"
else
  echo "no nodes found — cluster is already scaled down"
fi

# 3. Scale every pool on this cluster to 0. Scale (not delete) the pool
# object itself: Scaleway requires a cluster to keep at least one pool.
pool_ids="$(scw k8s pool list cluster-id="$cluster_id" region="$region" -o template='{{ .ID }}')"
if [ -z "$pool_ids" ]; then
  echo "cluster '$cluster_name' has no node pools — nothing to scale"
else
  while IFS= read -r pool_id; do
    [ -n "$pool_id" ] || continue
    echo "scaling pool $pool_id to 0 nodes"
    scw k8s pool update "$pool_id" region="$region" size=0 -w
  done <<<"$pool_ids"
fi

pvc_count="$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
cat <<EOF

Cluster '$cluster_name' ($env_name) scaled down — 0 nodes, control plane still running.

- PersistentVolumeClaims still Bound in the cluster: $pvc_count (none were touched)
- Load Balancers: deleted (recreated automatically on scaleway-scale-up.sh)
- Resume with: BK_CLUSTER_ENV=$env_name infra/cluster/scaleway-scale-up.sh

EOF
