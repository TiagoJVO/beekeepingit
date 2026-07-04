#!/usr/bin/env bash
# One-command bring-up for the local single k8s cluster (NFR-ARC-3).
# Idempotent: safe to re-run against an already-provisioned cluster.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cluster_name="beekeeping"

for bin in k3d kubectl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

if k3d cluster list "$cluster_name" >/dev/null 2>&1; then
  echo "cluster '$cluster_name' already exists — starting it (no-op if already running)"
  k3d cluster start "$cluster_name"
else
  echo "creating cluster '$cluster_name'"
  k3d cluster create --config "$script_dir/k3d-config.yaml"
fi

kubectl config use-context "k3d-$cluster_name"
kubectl cluster-info

cat <<'EOF'

Cluster ready. Next: install the platform umbrella chart, e.g.

  helm install beekeepingit infra/helm/beekeepingit \
    -f infra/helm/beekeepingit/environments/dev.yaml \
    --namespace beekeepingit-dev --create-namespace

EOF
