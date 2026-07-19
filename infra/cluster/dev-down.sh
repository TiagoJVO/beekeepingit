#!/usr/bin/env bash
# Single-command teardown for dev-up.sh (#22) — reverses it in order: uninstall
# the Authentik/MinIO Flux HelmReleases and the umbrella release (so CNPG/Helm
# get a clean shutdown instead of having their containers yanked), then delete
# the k3d cluster itself (down.sh — which also cleans up its own docker
# volumes/network, so nothing survives outside the cluster either way).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
namespace="beekeepingit-dev"

for bin in k3d kubectl helm flock git; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

if k3d cluster list beekeeping >/dev/null 2>&1; then
  echo "removing the Authentik/MinIO Flux HelmReleases"
  # These manifests live in the beekeepingit-gitops repo now (D-27/ADR-0018);
  # resolve a checkout (shallow clone, or a BEEKEEPINGIT_GITOPS_DIR override).
  gitops_dir="$("$script_dir/gitops-dir.sh")"
  "$script_dir/with-lock.sh" kubectl delete --ignore-not-found \
    -f "$gitops_dir/apps/dev/authentik-helmrelease.yaml" \
    -f "$gitops_dir/apps/dev/minio-helmrelease.yaml"

  echo "uninstalling the beekeepingit umbrella release"
  "$script_dir/with-lock.sh" helm uninstall beekeepingit --namespace "$namespace" || true
else
  echo "cluster 'beekeeping' does not exist — skipping release teardown"
fi

"$script_dir/down.sh"

# Stop the keep-alive heartbeat dev-up.sh started (see its own doc comment) —
# nothing left needs the distro pinned busy once the cluster is gone.
keepalive_pidfile="/tmp/beekeeping-keepalive.pid"
if [ -f "$keepalive_pidfile" ]; then
  pid="$(cat "$keepalive_pidfile")"
  kill "$pid" 2>/dev/null || true
  rm -f "$keepalive_pidfile"
  echo "stopped keep-alive heartbeat (pid $pid)"
fi
