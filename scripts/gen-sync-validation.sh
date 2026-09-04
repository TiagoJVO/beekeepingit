#!/usr/bin/env bash
# Regenerates the client's embedded copy of the shared sync-op validation
# description (docs/architecture/sync.md §9, D-12, #584).
#
# The description in contracts/validation/ is the SINGLE definition of the
# mechanical sync-op rules. The client cannot read a repo file at runtime (it
# ships as a web bundle), so the JSON is embedded verbatim into a generated
# Dart constant — verbatim, so the rule DATA cannot drift from the shared file.
# The committed output is checked in CI by client/test/core/validation/
# sync_validation_rules_test.dart, which compares the embedded bytes with the
# source file (the same "committed codegen must not be stale" convention the
# repo already applies to lib/l10n/gen).
#
# Usage: ./scripts/gen-sync-validation.sh   (from the repo root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo_root/contracts/validation/sync-ops.validation.json"
out="$repo_root/client/lib/core/validation/gen/sync_validation_rules.g.dart"

if [ ! -f "$src" ]; then
  echo "gen-sync-validation: $src not found" >&2
  exit 1
fi

# The JSON is embedded in a Dart raw triple-quoted string, so a literal ''' in
# the source would terminate it early and emit a file that does not compile —
# with an error pointing at the generated Dart, not at the JSON that caused it.
if grep -q "'''" "$src"; then
  echo "gen-sync-validation: $src contains ''' — it cannot be embedded in a Dart raw string" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"

{
  cat <<'HEADER'
// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Generated from contracts/validation/sync-ops.validation.json by
// scripts/gen-sync-validation.sh. Edit the JSON description and re-run that
// script; a stale copy fails
// client/test/core/validation/sync_validation_rules_test.dart in CI.
//
// The shared description (docs/architecture/sync.md §9, D-12, FR-OF-2) is the
// single definition of the mechanical sync-op validation rules. It is embedded
// here VERBATIM rather than translated into Dart literals, so the rule data on
// the client is byte-identical to the shared file and cannot silently drift
// from it. `SyncValidationRules.parse` (../sync_validation_rules.dart) turns it
// into rules; `SyncValidationRules.shared` does that once, lazily.

/// The shared sync-op validation description, verbatim.
const syncValidationRulesJson = r'''
HEADER
  cat "$src"
  printf "%s\n" "''';"
} >"$out"

echo "gen-sync-validation: wrote $out"
