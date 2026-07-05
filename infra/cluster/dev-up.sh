#!/usr/bin/env bash
# Single-command bring-up for the whole local dev environment (#22,
# NFR-ARC-2/NFR-ARC-3): the k3d cluster + CNPG operator (up.sh), the Flux
# controllers (a previously-manual prerequisite, see infra/gitops/README.md —
# made idempotent here so this script is genuinely self-contained from an
# empty cluster), the beekeepingit umbrella release (Postgres+PostGIS,
# Keycloak creds/realm, MinIO creds, gateway, PowerSync), the standalone
# Keycloak/MinIO Flux HelmReleases (applied directly, not via the `main`-
# tracking GitOps bootstrap — see the note below), and a smoke test.
#
# Deliberately does NOT apply `infra/gitops/clusters/dev/` (the one-time
# GitOps bootstrap that makes Flux auto-sync from this repo's `main` branch):
# that would deploy the umbrella chart from `main`, ignoring whatever's
# checked out locally — the opposite of what a pre-merge dev/test loop needs.
# See infra/gitops/README.md for the post-merge bootstrap step. Also skips the
# observability stack (#87) — it's not one of #22's components and its
# HelmRelease depends on that same bootstrap `GitRepository`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
chart_dir="$repo_root/infra/helm/beekeepingit"
namespace="beekeepingit-dev"

for bin in k3d kubectl helm flux flock; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

"$script_dir/up.sh"

echo
echo "installing/upgrading the Flux controllers (idempotent)"
flux install --components-extra=image-reflector-controller,image-automation-controller
flux check

echo
echo "fetching umbrella chart dependencies"
helm dependency build "$chart_dir"

echo
echo "installing/upgrading the beekeepingit umbrella release"
"$script_dir/with-lock.sh" helm upgrade --install beekeepingit "$chart_dir" \
  -f "$chart_dir/environments/dev.yaml" \
  --namespace "$namespace" --create-namespace --wait

echo
echo "applying the Keycloak/MinIO Flux HelmReleases directly (local-only, not GitOps-synced)"
# Both files' `dependsOn: [beekeepingit]` targets the *HelmRelease object*
# named "beekeepingit" that only exists once the cluster is GitOps-bootstrapped
# (infra/gitops/clusters/dev/) — which this script deliberately skips (see the
# note above). Stripped here for this direct-apply path only (committed files
# are untouched): the umbrella release just installed with `--wait` already
# guarantees the credential Secret/ConfigMap these reference exist, which is
# all `dependsOn` was ensuring in the first place. Applied one file at a time
# (not piped together) since neither file ends with its own trailing `---`, so
# concatenating them loses the document boundary between the two.
for f in keycloak-helmrelease.yaml minio-helmrelease.yaml; do
  sed '/^  dependsOn:$/,+1d' "$repo_root/infra/gitops/apps/dev/$f" \
    | "$script_dir/with-lock.sh" kubectl apply -f -
done

echo
echo "waiting for the PowerSync rollout"
kubectl -n "$namespace" rollout status deployment/beekeepingit-powersync --timeout=180s

echo
echo "waiting for Keycloak/MinIO (Keycloak's JVM boot + realm import can take a couple of minutes)"
kubectl -n "$namespace" wait --for=condition=ready pod -l app.kubernetes.io/instance=keycloak --timeout=300s
kubectl -n "$namespace" wait --for=condition=ready pod -l app.kubernetes.io/instance=minio --timeout=180s

echo
echo "running helm test (PostGIS smoke query)"
helm test beekeepingit --namespace "$namespace"

cat <<EOF

Local dev environment ready. See infra/README.md#verify-the-environment for
the PostGIS/Keycloak/MinIO/PowerSync/gateway smoke checks.
EOF
