#!/usr/bin/env bash
# Validate a commit message against Conventional Commits (see CONTRIBUTING.md).
# Invoked by the lefthook `commit-msg` hook with the message-file path as $1.
set -euo pipefail

msg_file="${1:?commit message file path required}"

# First non-empty, non-comment line = the header.
header=$(grep -vE '^\s*#' "$msg_file" | sed '/^[[:space:]]*$/d' | head -1 || true)

# Let git-generated merge/revert/fixup/squash messages through.
case "$header" in
  Merge*|Revert*|"fixup! "*|"squash! "*) exit 0 ;;
esac

pattern='^(feat|fix|docs|refactor|test|chore|perf|ci|build)(\([a-z0-9._/-]+\))?!?: .+'
if ! printf '%s' "$header" | grep -qE "$pattern"; then
  echo "✗ Commit message must follow Conventional Commits:"
  echo "      <type>(<scope>): <subject>"
  echo "  types: feat|fix|docs|refactor|test|chore|perf|ci|build"
  echo "  e.g.:  feat(apiaries): add CRUD (FR-AP-1, #123)"
  echo "  got:   ${header:-<empty>}"
  exit 1
fi
