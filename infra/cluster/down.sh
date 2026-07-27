#!/usr/bin/env bash
# Teardown for the local single k8s cluster. Deletes the k3d cluster (nodes,
# its docker network, and the load-balancer container) so re-running up.sh
# starts from a clean state — no orphaned resources.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional local config from infra/cluster/.env (see .env.example).
# shellcheck disable=SC1091 # resolved at runtime next to this script
. "$script_dir/env.sh"

cluster_name="beekeeping"

for bin in k3d flock; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# Same lock as up.sh (see infra/README.md) — most important here, since this
# deletes the whole cluster out from under anyone else using it.
lockfile="/tmp/k3d-${cluster_name}.lock"
exec 200>"$lockfile"
if ! flock -w 300 200; then
  echo "error: timed out waiting for the '$cluster_name' cluster lock — another session appears to be using it" >&2
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
