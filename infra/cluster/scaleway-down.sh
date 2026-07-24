#!/usr/bin/env bash
# Teardown for a Scaleway Kapsule cluster (D-26) — staging by default, prod
# via BK_CLUSTER_ENV=prod. Deletes the cluster (and its node pool) so
# re-running scaleway-up.sh starts from a clean state. This is a real, billed
# cloud resource — unlike the local k3d teardown, there is no "just recreate
# it" safety net if this is run by mistake against a cluster holding anything
# you care about. (cluster-ops.yml adds a type-the-cluster-name confirmation
# in front of this for exactly that reason.)
#
# Credentials come from the environment, same as scaleway-up.sh: a `scw init`
# profile, or SCW_ACCESS_KEY/SCW_SECRET_KEY/... env vars — locally via
# infra/cluster/.env (see .env.example), in CI via GitHub secrets.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional local config/secrets from infra/cluster/.env (see .env.example).
# shellcheck disable=SC1091 # resolved at runtime next to this script
. "$script_dir/env.sh"

env_name="${BK_CLUSTER_ENV:-staging}"
case "$env_name" in
  staging | prod) ;;
  *)
    echo "error: BK_CLUSTER_ENV must be 'staging' or 'prod' (got '$env_name')" >&2
    exit 1
    ;;
esac

cluster_name="${SCW_K8S_CLUSTER_NAME:-beekeepingit-$env_name}"
region="${SCW_REGION:-fr-par}"

if ! command -v scw >/dev/null 2>&1; then
  echo "error: 'scw' not found on PATH" >&2
  exit 1
fi

# Same credentials pre-flight as scaleway-up.sh: without a `scw init` profile,
# a profile-less run needs all four SCW_* variables.
if [ ! -f "${HOME}/.config/scw/config.yaml" ]; then
  missing=""
  for v in SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_ORGANIZATION_ID; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    echo "error: no scw profile (~/.config/scw/config.yaml) and missing:$missing" >&2
    echo "either run 'scw init' once, or set all four SCW_* variables" >&2
    echo "(locally via infra/cluster/.env — see .env.example; in CI via GitHub secrets)" >&2
    exit 1
  fi
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
