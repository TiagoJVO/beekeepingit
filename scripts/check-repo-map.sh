#!/usr/bin/env bash
# Verify that every tracked top-level directory has a row in CLAUDE.md's repo map and a line
# in README.md's repository-layout tree (definition-of-done: "new top-level directory ⇒ map
# rows, in the same PR"). Both files are entry-point maps; a directory missing from them is
# invisible to the next contributor, human or agent. Runs from `task repo:lint` (CI + local).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0
# Tracked paths only, so ignored/untracked build output (node_modules, .dart_tool) never counts.
for dir in $(git ls-files | grep '/' | cut -d/ -f1 | sort -u); do
  case "$dir" in
    .git) continue ;;
  esac
  # CLAUDE.md lists a directory as `dir/` (or a sub-path like `.claude/rules/`).
  if ! grep -qF "\`$dir/" CLAUDE.md; then
    echo "✗ [repo-map] '$dir/' has no row in CLAUDE.md's repo map"
    status=1
  fi
  # README.md's layout tree lists it as `dir/` too.
  if ! grep -qE "(^|[^a-zA-Z0-9_.-])$dir/" README.md; then
    echo "✗ [repo-map] '$dir/' is missing from README.md's repository-layout tree"
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "› [repo-map] every top-level directory is mapped in CLAUDE.md and README.md"
fi
exit "$status"
