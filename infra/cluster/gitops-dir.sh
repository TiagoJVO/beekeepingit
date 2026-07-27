#!/usr/bin/env bash
# Resolves a local checkout of the beekeepingit-gitops repo and prints its path
# on stdout. The Flux manifests (clusters/, apps/) were split out of this repo
# into TiagoJVO/beekeepingit-gitops per D-27/ADR-0018, but the local dev/CI
# tooling here (dev-up.sh, dev-down.sh) still needs the standalone
# Authentik/MinIO HelmRelease manifests that now live there.
#
# Resolution order:
#   1. BEEKEEPINGIT_GITOPS_DIR — an existing local checkout (use this offline, or
#      when iterating on the gitops repo alongside this one). Must contain apps/.
#   2. otherwise, a shallow clone of BEEKEEPINGIT_GITOPS_REPO into a temp dir.
#
# Only stdout is the resolved path; all progress/errors go to stderr so callers
# can capture it with `dir="$(gitops-dir.sh)"`.
set -euo pipefail

# Optional local config from infra/cluster/.env (see .env.example) — lets
# BEEKEEPINGIT_GITOPS_DIR/BEEKEEPINGIT_GITOPS_REPO live there for standalone
# invocations (callers that already sourced env.sh just re-inherit the same
# values through the environment).
# shellcheck disable=SC1091 # resolved at runtime next to this script
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

GITOPS_REPO="${BEEKEEPINGIT_GITOPS_REPO:-https://github.com/TiagoJVO/beekeepingit-gitops}"

if [ -n "${BEEKEEPINGIT_GITOPS_DIR:-}" ]; then
  if [ ! -d "$BEEKEEPINGIT_GITOPS_DIR/apps" ]; then
    echo "error: BEEKEEPINGIT_GITOPS_DIR='$BEEKEEPINGIT_GITOPS_DIR' has no apps/ dir" >&2
    exit 1
  fi
  echo "$BEEKEEPINGIT_GITOPS_DIR"
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: 'git' not found on PATH (needed to clone $GITOPS_REPO; or set BEEKEEPINGIT_GITOPS_DIR)" >&2
  exit 1
fi

dest="$(mktemp -d)/beekeepingit-gitops"
echo "cloning $GITOPS_REPO (shallow) into $dest" >&2
git clone --depth 1 --quiet "$GITOPS_REPO" "$dest" >&2
echo "$dest"
