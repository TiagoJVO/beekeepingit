#!/usr/bin/env bash
# Serializes a command against other concurrent sessions (e.g. another agent)
# touching the same shared local cluster — the same lock up.sh/down.sh take
# themselves. Use this for any other cluster-mutating command (helm
# install/upgrade/uninstall, ad-hoc kubectl apply, etc.) — see infra/README.md.
#
# Usage: infra/cluster/with-lock.sh <command> [args...]
# Example: infra/cluster/with-lock.sh helm install beekeepingit infra/helm/beekeepingit \
#            -f infra/helm/beekeepingit/environments/dev.yaml --namespace beekeepingit-dev --create-namespace
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  echo "error: 'flock' not found on PATH" >&2
  exit 1
fi

cluster_name="beekeeping"
# Keyed by cluster name, not this script's path, so it's the same lock no
# matter which git worktree invokes it.
lockfile="/tmp/k3d-${cluster_name}.lock"

exec 200>"$lockfile"
if ! flock -w 300 200; then
  echo "error: timed out waiting for the '$cluster_name' cluster lock — another session appears to be using it" >&2
  exit 1
fi

exec "$@"
