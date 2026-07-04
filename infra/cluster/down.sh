#!/usr/bin/env bash
# Teardown for the local single k8s cluster. Deletes the k3d cluster (nodes,
# its docker network, and the load-balancer container) so re-running up.sh
# starts from a clean state — no orphaned resources.
set -euo pipefail

cluster_name="beekeeping"

if ! command -v k3d >/dev/null 2>&1; then
  echo "error: 'k3d' not found on PATH" >&2
  exit 1
fi

if k3d cluster list "$cluster_name" >/dev/null 2>&1; then
  k3d cluster delete "$cluster_name"
  echo "cluster '$cluster_name' deleted"
else
  echo "cluster '$cluster_name' does not exist — nothing to do"
fi

# k3d cleans up its own docker volumes/network on cluster delete. Surface
# anything unexpected left behind (e.g. from a manually-edited config) so it
# doesn't silently accumulate.
orphans="$(docker volume ls --filter "label=app=k3d" --filter "label=k3d.cluster=$cluster_name" -q 2>/dev/null || true)"
if [ -n "$orphans" ]; then
  echo "warning: orphaned k3d volumes found for '$cluster_name':" >&2
  echo "$orphans" >&2
fi
