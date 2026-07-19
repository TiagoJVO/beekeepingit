#!/usr/bin/env bash
# One-command bring-up for the Scaleway Kapsule staging cluster (D-26).
# Idempotent: safe to re-run against an already-provisioned cluster.
#
# Prerequisites (Phase 0, done once by hand, not by this script):
#   - a Scaleway account with billing set up, in an EU region
#   - `scw init` already run (stores the API access/secret key + default
#     project/region — see https://www.scaleway.com/en/docs/console/account/how-to/create-api-keys/)
#   - a real domain, with $STAGING_APP_HOST / $STAGING_AUTH_HOST DNS records
#     pointyable at the LoadBalancer this script provisions (see step 3 below
#     for how to learn its IP once the ingress controller is up)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cluster_name="${SCW_K8S_CLUSTER_NAME:-beekeepingit-staging}"
region="${SCW_REGION:-fr-par}"
# DEV1-M (3vCPU/4GB) was the original default but proved insufficient on the
# first staging bring-up (D-26): the full stack (CNPG, Traefik, cert-manager,
# Flux's 6 controllers, Postgres, Authentik + its bundled Postgres, MinIO,
# PowerSync, PWA, 7 Go services) pushed memory *requests* alone to ~90% of
# allocatable, leaving no room for one-off Jobs (Authentik's blueprint-apply
# worker, MinIO's bucket-creation post-install hook) to even get scheduled —
# both sat Pending on "Insufficient memory" indefinitely. DEV1-L (4vCPU/8GB,
# ~€30.66/mo vs DEV1-M's ~€14.26/mo) gives real headroom instead of inching
# up; revisit down if usage stays low once the stack is stable.
node_type="${SCW_NODE_TYPE:-DEV1-L}"

for bin in scw kubectl helm flux; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# Same flock idiom as infra/cluster/up.sh, but note two caveats that don't
# carry over here. (1) up.sh's lock protects one shared *local* cluster from
# concurrent sessions on the *same machine* (it's a plain local lockfile).
# This remote cluster can equally be reached from any machine with `scw init`
# run against the same Scaleway project, so even when available this lock
# only protects against a race with another session on *this* machine — it
# is not distributed coordination. Keep this project single-maintainer-
# operated until that's addressed (e.g. locking at the Scaleway resource
# level, or routing all real changes through CI). (2) unlike up.sh's WSL2/
# Linux environment, `flock` is a util-linux tool, not bundled with Git
# Bash on Windows — so it's treated as optional here, not required.
if command -v flock >/dev/null 2>&1; then
  lockfile="/tmp/scw-k8s-${cluster_name}.lock"
  exec 200>"$lockfile"
  if ! flock -w 300 200; then
    echo "error: timed out waiting for the '$cluster_name' cluster lock — another session on this machine appears to be using it" >&2
    exit 1
  fi
else
  echo "warning: 'flock' not found — skipping the same-machine concurrency lock (harmless for single-operator use)" >&2
fi

# 1. Create (or find) the cluster.
cluster_id="$(scw k8s cluster list name="$cluster_name" region="$region" -o template='{{ .ID }}' 2>/dev/null || true)"
if [ -n "$cluster_id" ]; then
  echo "cluster '$cluster_name' already exists (id $cluster_id) in $region — reusing it"
else
  # Look up the latest supported version instead of hardcoding one:
  # Kapsule only supports the last ~3 minor releases (~12mo each per
  # https://www.scaleway.com/en/docs/kubernetes/reference-content/version-support-policy/),
  # so a pinned constant here would eventually create a cluster with a
  # rejected version. Override with SCW_K8S_VERSION if you want a specific
  # one instead (e.g. to match an existing cluster's version during upgrade
  # testing).
  k8s_version="${SCW_K8S_VERSION:-}"
  if [ -z "$k8s_version" ]; then
    k8s_version="$(scw k8s version list -o template='{{ .Name }}' | sort -V | tail -1)"
    echo "no SCW_K8S_VERSION set — using latest supported version: $k8s_version"
  fi
  echo "creating cluster '$cluster_name' in $region (version $k8s_version, node type $node_type)"
  cluster_id="$(scw k8s cluster create \
    name="$cluster_name" \
    region="$region" \
    version="$k8s_version" \
    cni=cilium \
    pools.0.name=default \
    pools.0.node-type="$node_type" \
    pools.0.size=1 \
    pools.0.autohealing=true \
    pools.0.autoscaling=false \
    -o template='{{ .ID }}')"
  echo "waiting for cluster '$cluster_name' (id $cluster_id) to become ready — this takes a few minutes"
  scw k8s cluster wait "$cluster_id" region="$region"
fi

# 2. Fetch kubeconfig. `kubeconfig install` sets it as the active context
# itself — not forcing a guessed context name here since it isn't documented
# and getting it wrong would hard-fail this script right after cluster
# creation succeeds. Confirm the active context is the right one instead.
scw k8s kubeconfig install "$cluster_id" region="$region"
echo "active kubectl context: $(kubectl config current-context)"
kubectl cluster-info

# 3. Cluster-scoped prerequisites — mirrors infra/cluster/up.sh's CNPG
# install, plus two things k3d bundled for free that Kapsule doesn't: an
# ingress controller and cert-manager (dev only ever needed a self-signed
# cert; a real public staging host needs a trusted one — see
# charts/gateway/values.yaml's certManager.* values).
echo "installing/upgrading the CloudNativePG operator"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo update cnpg >/dev/null
helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait

echo "installing/upgrading Traefik (ingress controller — k3d bundles this, Kapsule doesn't)"
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace --wait

echo "installing/upgrading cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --wait \
  --set crds.enabled=true

# 4. Flux controllers (same as infra/gitops/README.md's dev prerequisite —
# imperative, not GitOps-managed, per ADR-0009). Base controllers only: Flux is
# read-only (D-27/ADR-0018 dropped image-automation).
echo "installing Flux controllers"
flux install
flux check

cat <<EOF

Cluster ready. Remaining one-time setup, in order:

1. Point DNS (A/AAAA records for \$STAGING_APP_HOST / \$STAGING_AUTH_HOST) at
   Traefik's LoadBalancer external IP:

     kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

2. Create the cert-manager ClusterIssuer (not templated here — it needs a
   real ACME account email; see infra/gitops/README.md for where this lands
   once staging is bootstrapped).

3. Bootstrap GitOps for this cluster (see infra/gitops/README.md):

     kubectl apply -f infra/gitops/clusters/staging/

EOF
