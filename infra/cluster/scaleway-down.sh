#!/usr/bin/env bash
# FULL, PERMANENT teardown for a Scaleway Kapsule cluster (D-26) — staging by
# default, prod via BK_CLUSTER_ENV=prod. Deletes the cluster, its node pool,
# AND its block-storage volumes + Load Balancers (with-additional-resources),
# so re-running scaleway-up.sh starts from a genuinely clean, empty state.
# This is a real, billed cloud resource — unlike the local k3d teardown,
# there is no "just recreate it" safety net if this is run by mistake against
# a cluster holding anything you care about. (cluster-ops.yml adds a
# type-the-cluster-name confirmation in front of this for exactly that
# reason.)
#
# For routine "stop paying for compute between sessions" teardown that KEEPS
# all data (Postgres/Authentik/MinIO volumes, Flux state) intact, use
# scaleway-scale-down.sh instead (#539) — this script is for when you
# actually want to destroy the environment, not pause it.
#
# Credentials come from the environment, same as scaleway-up.sh: a `scw init`
# profile, or SCW_ACCESS_KEY/SCW_SECRET_KEY/... env vars — locally via
# infra/cluster/.env (see .env.example), in CI via GitHub secrets.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra/cluster/scw-common.sh
. "$script_dir/scw-common.sh"

cluster_id="$(scw k8s cluster list name="$cluster_name" region="$region" -o template='{{ .ID }}' 2>/dev/null || true)"
if [ -n "$cluster_id" ]; then
  echo "deleting cluster '$cluster_name' (id $cluster_id) in $region — this also deletes its node pool(s)"
  scw k8s cluster delete "$cluster_id" region="$region" with-additional-resources=true
  echo "cluster '$cluster_name' deletion requested"
else
  echo "cluster '$cluster_name' does not exist in $region — nothing to do"
fi
