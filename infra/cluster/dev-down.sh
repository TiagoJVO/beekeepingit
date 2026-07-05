#!/usr/bin/env bash
# Single-command teardown for dev-up.sh (#22) — reverses it in order: uninstall
# the Keycloak/MinIO Flux HelmReleases and the umbrella release (so CNPG/Helm
# get a clean shutdown instead of having their containers yanked), then delete
# the k3d cluster itself (down.sh — which also cleans up its own docker
# volumes/network, so nothing survives outside the cluster either way).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
namespace="beekeepingit-dev"

for bin in k3d kubectl helm flock; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

if k3d cluster list beekeeping >/dev/null 2>&1; then
  echo "removing the Keycloak/MinIO Flux HelmReleases"
  "$script_dir/with-lock.sh" kubectl delete --ignore-not-found \
    -f "$repo_root/infra/gitops/apps/dev/keycloak-helmrelease.yaml" \
    -f "$repo_root/infra/gitops/apps/dev/minio-helmrelease.yaml"

  echo "uninstalling the beekeepingit umbrella release"
  "$script_dir/with-lock.sh" helm uninstall beekeepingit --namespace "$namespace" || true
else
  echo "cluster 'beekeeping' does not exist — skipping release teardown"
fi

"$script_dir/down.sh"
