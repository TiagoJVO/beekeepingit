#!/usr/bin/env bash
# Sourced (not executed) by the infra/cluster scripts: loads optional local
# configuration/secrets from infra/cluster/.env (gitignored — see .env.example
# for every variable). This is the local counterpart of the GitHub Actions
# secrets/variables that .github/workflows/cluster-ops.yml injects: GitHub
# secrets are write-only (an API/CLI can set them but never read them back), so
# manual runs load the same variable names from this file instead.
#
# Precedence follows the usual dotenv convention: values already exported in
# the calling shell WIN over the file, so one-off overrides like
# `BK_CLUSTER_ENV=prod ./scaleway-up.sh` behave as expected.

_env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [ -f "$_env_file" ]; then
  # Snapshot the already-exported environment, source the file with auto-export,
  # then re-apply the snapshot so pre-existing exports take precedence.
  _pre_env="$(export -p)"
  set -a
  # shellcheck disable=SC1090 # user-provided, gitignored file
  . "$_env_file"
  set +a
  eval "$_pre_env"
  unset _pre_env
fi
unset _env_file
