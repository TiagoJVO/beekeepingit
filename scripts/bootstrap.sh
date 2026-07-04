#!/usr/bin/env bash
# One-command dev bootstrap for BeekeepingIT.
# Installs mise (if missing), every pinned toolchain/tool from mise.toml, and git hooks.
#
# Usage:  ./scripts/bootstrap.sh
# Assumes a POSIX shell (Linux, macOS, or WSL2 on Windows) with curl + git.
set -euo pipefail

echo "→ BeekeepingIT bootstrap"

if ! command -v mise >/dev/null 2>&1; then
  echo "→ mise not found — installing from https://mise.run ..."
  curl -fsSL https://mise.run | sh
  export PATH="$HOME/.local/bin:$PATH"
  echo "  NOTE: add mise to your shell so it activates in new terminals, e.g. for bash:"
  # Printed verbatim as a copy-paste example; must not expand.
  # shellcheck disable=SC2016
  echo '        echo '\''eval "$(mise activate bash)"'\'' >> ~/.bashrc'
fi

echo "→ Trusting this repo's mise.toml (required before mise will read it) ..."
mise trust

echo "→ Installing toolchains + tools from mise.toml ..."
mise install

echo "→ Installing git hooks (lefthook) ..."
mise exec -- lefthook install

echo "✓ Bootstrap complete."
echo "  Next: run  mise exec -- task --list   (or just  task --list  once mise is activated)."
