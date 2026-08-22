#!/usr/bin/env bash
# Resume a Scaleway Kapsule environment previously paused with
# scaleway-scale-down.sh (#539, D-26) — staging by default, prod via
# BK_CLUSTER_ENV=prod. Scales the node pool back up; every pod (CNPG
# Postgres, Authentik, MinIO) reschedules onto the new nodes and reattaches
# its already-`Bound` PersistentVolumeClaim automatically via standard
# Kubernetes CSI semantics — the PVC/PV/CNPG-`Cluster` objects never left the
# API, because the control plane never stopped. There is no volume
# reattachment logic here because there is nothing to reattach.
#
# This is NOT scaleway-up.sh. That script creates a cluster from nothing (or
# reuses one that already exists) — use it for a genuinely fresh environment,
# or after scaleway-down.sh destroyed one. This script REQUIRES the cluster
# to already exist (from a prior scaleway-up.sh) and fails clearly if it
# doesn't, rather than silently standing up an empty one under the same name.
#
# What it does, in order:
#   1. Pre-flight: fail if the cluster doesn't exist.
#   2. Scale every node pool on the cluster back up (default: 1 node, same as
#      scaleway-up.sh's original pool; override with SCW_NODE_POOL_SIZE).
#   3. Wait for a node to become Ready.
#   4. Re-run the same cluster-scoped-prerequisite install scaleway-up.sh does
#      (CNPG operator, Traefik — which recreates the LoadBalancer
#      scaleway-scale-down.sh deleted — cert-manager, Flux controllers): the
#      pods providing these lived on the nodes that were just deleted, so
#      they need the same bring-up steps a first-ever install does. See
#      scw-cluster-prereqs.sh.
#
# Credentials/env come from the same place as scaleway-up.sh/-down.sh: a
# `scw init` profile, or SCW_ACCESS_KEY/SCW_SECRET_KEY/... env vars — locally
# via infra/cluster/.env (see .env.example), in CI via GitHub secrets. The
# same optional Cloudflare dynamic-DNS variables as scaleway-up.sh apply here
# too (CF_API_TOKEN/CF_ZONE_ID/APP_HOST/AUTH_HOST) — a fresh LoadBalancer
# means a fresh IP to (re-)push.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/cluster/scw-common.sh
. "$script_dir/scw-common.sh"
# shellcheck source=infra/cluster/scw-cluster-prereqs.sh
. "$script_dir/scw-cluster-prereqs.sh"

app_host="${APP_HOST:-${STAGING_APP_HOST:-}}"
auth_host="${AUTH_HOST:-${STAGING_AUTH_HOST:-}}"
target_size="${SCW_NODE_POOL_SIZE:-1}"

for bin in kubectl helm flux; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# 1. Pre-flight: this script resumes an existing, paused environment — it
# must not silently create a brand-new one under the same name if the
# cluster was actually destroyed (scaleway-down.sh) or never brought up.
# No `2>/dev/null || true` here (or on the pool lookup below): a transient
# `scw` failure must abort loudly via `set -e`, not be swallowed into the
# same "doesn't exist" message a genuinely absent cluster gets.
cluster_id="$(scw k8s cluster list name="$cluster_name" region="$region" -o template='{{ .ID }}')"
if [ -z "$cluster_id" ]; then
  echo "error: cluster '$cluster_name' does not exist in $region — nothing to scale up" >&2
  echo "run scaleway-up.sh instead to create it" >&2
  exit 1
fi

scw k8s kubeconfig install "$cluster_id" region="$region"
echo "active kubectl context: $(kubectl config current-context)"

# 2. Scale every pool on this cluster back up.
pool_ids="$(scw k8s pool list cluster-id="$cluster_id" region="$region" -o template='{{ .ID }}')"
if [ -z "$pool_ids" ]; then
  echo "error: cluster '$cluster_name' has no node pools — cannot scale up (this shouldn't happen; a Kapsule cluster always keeps at least one pool object)" >&2
  exit 1
fi
while IFS= read -r pool_id; do
  [ -n "$pool_id" ] || continue
  echo "scaling pool $pool_id to $target_size node(s)"
  scw k8s pool update "$pool_id" region="$region" size="$target_size" -w
done <<<"$pool_ids"

# 3. Wait for at least one node to be Ready before installing anything onto it.
echo "waiting for at least one node to become Ready"
for _ in $(seq 1 60); do
  ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)"
  [ "${ready_nodes:-0}" -gt 0 ] && break
  sleep 5
done
if [ "${ready_nodes:-0}" -eq 0 ]; then
  echo "error: no node became Ready within 5 minutes" >&2
  exit 1
fi
kubectl cluster-info

# 4. Cluster-scoped prerequisites — the pods providing these were deleted
# along with the nodes, so they need reinstalling exactly as scaleway-up.sh
# installs them on a first-ever bring-up.
install_cluster_prereqs

cat <<EOF

Cluster '$cluster_name' ($env_name) scaled up.

- DNS: if CF_API_TOKEN was set, the A records for the app/auth hosts were
  re-pushed to Cloudflare above (the LoadBalancer got a new IP). Otherwise
  point them at Traefik's LoadBalancer IP manually:

    kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

- Every PersistentVolumeClaim that was Bound before scale-down is still
  Bound — CNPG Postgres, Authentik, and MinIO reattach their existing data
  automatically as their pods reschedule. Watch convergence with:

    kubectl get pods -A -w

EOF
