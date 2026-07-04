#!/usr/bin/env bash
# One-command bring-up for the local single k8s cluster (NFR-ARC-3).
# Idempotent: safe to re-run against an already-provisioned cluster.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cluster_name="beekeeping"

for bin in k3d kubectl helm flock; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# Serialize against other concurrent sessions (e.g. another agent) touching the
# same shared local cluster — keyed by cluster name, not this script's path, so
# it's the same lock no matter which git worktree invokes it (see
# infra/README.md). Held for the whole script, since bring-up itself mutates
# the shared cluster.
lockfile="/tmp/k3d-${cluster_name}.lock"
exec 200>"$lockfile"
if ! flock -w 300 200; then
  echo "error: timed out waiting for the '$cluster_name' cluster lock — another session appears to be using it" >&2
  exit 1
fi

if k3d cluster list "$cluster_name" >/dev/null 2>&1; then
  echo "cluster '$cluster_name' already exists — starting it (no-op if already running)"
  k3d cluster start "$cluster_name"
else
  echo "creating cluster '$cluster_name'"
  k3d cluster create --config "$script_dir/k3d-config.yaml"
fi

kubectl config use-context "k3d-$cluster_name"
kubectl cluster-info

# The CNPG operator is cluster-scoped (its CRDs/controller aren't per-release),
# so — like k3d's bundled Traefik — it's a cluster prerequisite installed here
# rather than a subchart of the per-environment umbrella release (see ADR-0008
# and infra/helm/beekeepingit/charts/postgres/Chart.yaml). Idempotent: `upgrade
# --install` is a no-op reconcile if it's already there.
echo "installing/upgrading the CloudNativePG operator"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo update cnpg >/dev/null
helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait

cat <<'EOF'

Cluster ready. Next: install the platform umbrella chart, e.g.

  helm install beekeepingit infra/helm/beekeepingit \
    -f infra/helm/beekeepingit/environments/dev.yaml \
    --namespace beekeepingit-dev --create-namespace

EOF
