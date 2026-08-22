#!/usr/bin/env bash
# Sourced (not executed) by every infra/cluster/scaleway-*.sh script. Resolves
# the target environment, cluster name/region, and Scaleway credentials, then
# takes the same-machine concurrency lock — the preamble all four
# scaleway-{up,down,scale-up,scale-down}.sh scripts need identically. Factored
# out (#539) rather than re-duplicating scaleway-up.sh's original inline copy
# a third and fourth time.
#
# Callers: source this near the top, right after `set -euo pipefail`. On
# return, env_name/cluster_name/region are set and exported for use by the
# caller, credentials are confirmed present (a `scw init` profile or all four
# SCW_* variables), and — best-effort — the /tmp/scw-k8s-<cluster>.lock flock
# is held for the rest of the script's lifetime (fd 200; released
# automatically on exit). Callers that need more than the `scw` binary itself
# (kubectl/helm/flux) still check for those separately.
#
# Same-machine-only lock, note two caveats. (1) This remote cluster can
# equally be reached from any machine with credentials for the same Scaleway
# project — including the GitHub Actions runners cluster-ops.yml uses — so
# even when available this lock only protects against a race with another
# session on *this* machine, not distributed coordination. Keep this project
# single-maintainer-operated until that's addressed (e.g. locking at the
# Scaleway resource level, or routing all real changes through CI). (2)
# `flock` is a util-linux tool, not bundled with Git Bash on Windows, so it's
# treated as optional here, not required (unlike infra/cluster/up.sh's
# WSL2/Linux-only local-cluster lock).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# shellcheck disable=SC2034 # consumed by every scaleway-*.sh script that sources this file, not used in this file itself
region="${SCW_REGION:-fr-par}"

if ! command -v scw >/dev/null 2>&1; then
  echo "error: 'scw' not found on PATH" >&2
  exit 1
fi

# Fail fast with a useful message when Scaleway credentials are missing or
# incomplete — otherwise the first `scw` call fails mid-run with a bare
# denied/401. Without a `scw init` profile, a profile-less run needs all four.
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
