#!/usr/bin/env bash
# One-command bring-up for the local single k8s cluster (NFR-ARC-3).
# Idempotent: safe to re-run against an already-provisioned cluster.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional local config from infra/cluster/.env (see .env.example) — the local
# cluster needs no external secrets (in-cluster ones are chart-generated,
# NFR-SEC); sourced for consistency with the other cluster scripts so any
# variable set there applies uniformly.
# shellcheck disable=SC1091 # resolved at runtime next to this script
. "$script_dir/env.sh"
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

# k3d prints "Cluster created successfully" once the container is up, but k3s's
# API server can still be initializing behind it — and the next kubectl call is
# a DISCOVERY call, which then fails with "the server is currently unable to
# handle the request" (ServiceUnavailable) and, under `set -e`, aborts bring-up
# before a single thing is installed. That is a pure cold-start race: it hits a
# fresh CI runner far more often than a warm local machine, and the failure
# looks nothing like its cause (the cluster IS there, and re-running usually
# passes). Poll the API server's own `/readyz` endpoint rather than sleeping a
# fixed guess — it reports ready only once the server can actually serve.
echo "waiting for the API server to become ready"
api_deadline=$((SECONDS + 180))
until [ "$(kubectl get --raw='/readyz' 2>/dev/null || true)" = "ok" ]; do
  if [ "$SECONDS" -ge "$api_deadline" ]; then
    echo "error: the API server did not become ready within 180s" >&2
    exit 1
  fi
  sleep 2
done

kubectl cluster-info

# The CNPG operator is cluster-scoped (its CRDs/controller aren't per-release),
# so — like k3d's bundled Traefik — it's a cluster prerequisite installed here
# rather than a subchart of the per-environment umbrella release (see ADR-0008
# and infra/helm/beekeepingit/charts/postgres/Chart.yaml). Idempotent: `upgrade
# --install` is a no-op reconcile if it's already there.
# Pulled from CNPG's OCI registry rather than the classic
# `https://cloudnative-pg.github.io/charts` Helm repo: that URL now 301s to
# `https://cloudnative-pg.io/charts/index.yaml`, and that domain's authoritative
# nameservers are refusing queries ("No Reachable Authority at delegation"), so
# `helm repo add` follows the redirect into a host that doesn't resolve and
# bring-up dies before installing anything. The same chart releases are pushed
# to `ghcr.io/cloudnative-pg/charts` by upstream's own release workflow, and
# that path depends on neither the redirect nor the broken domain. OCI charts
# are referenced directly — there is no repo to add or update.
echo "installing/upgrading the CloudNativePG operator"
helm upgrade --install cnpg-operator oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait

cat <<'EOF'

Cluster ready. Next: install the platform umbrella chart, e.g.

  helm install beekeepingit infra/helm/beekeepingit \
    -f infra/helm/beekeepingit/environments/dev.yaml \
    --namespace beekeepingit-dev --create-namespace

EOF
