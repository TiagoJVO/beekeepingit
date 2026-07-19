#!/usr/bin/env bash
# Teardown for the Scaleway Kapsule staging cluster (D-26). Deletes the
# cluster (and its node pool) so re-running scaleway-up.sh starts from a
# clean state. This is a real, billed cloud resource — unlike the local k3d
# teardown, there is no "just recreate it" safety net if this is run by
# mistake against a cluster holding anything you care about.
set -euo pipefail

cluster_name="${SCW_K8S_CLUSTER_NAME:-beekeepingit-staging}"
region="${SCW_REGION:-fr-par}"

if ! command -v scw >/dev/null 2>&1; then
  echo "error: 'scw' not found on PATH" >&2
  exit 1
fi

# Same lock as scaleway-up.sh (machine-local only, and optional — `flock` is
# a util-linux tool, not bundled with Git Bash on Windows — see its comment).
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

cluster_id="$(scw k8s cluster list name="$cluster_name" region="$region" -o template='{{ .ID }}' 2>/dev/null || true)"
if [ -n "$cluster_id" ]; then
  echo "deleting cluster '$cluster_name' (id $cluster_id) in $region — this also deletes its node pool(s)"
  scw k8s cluster delete "$cluster_id" region="$region" with-additional-resources=true
  echo "cluster '$cluster_name' deletion requested"
else
  echo "cluster '$cluster_name' does not exist in $region — nothing to do"
fi
