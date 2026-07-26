#!/usr/bin/env bash
# Guard: the admin audience-override scope mapping must be attached to ONLY the
# admin provider (#460, #456, NFR-SEC-1).
#
# The Authentik blueprint defines a scope mapping `scope-admin-audience` whose
# expression OVERRIDES a minted token's `iss`/`aud` so an admin token is accepted
# by the domain services (which validate `aud` contains `beekeepingit-pwa`). ANY
# oauth2provider that references this mapping in its `property_mappings` inherits
# that acceptance — so if a future PR silently attached it to another provider,
# that provider's clients would be accepted by every service too, widening the
# trust boundary with no other change. This check fails unless EXACTLY the
# `provider-beekeepingit-admin` entry references it.
#
# The assertion itself lives in scripts/check-scope-mapping-provider.sh (shared
# with the #465 platform-operator guard); this wrapper only pins the mapping this
# repo must guard. An optional argument overrides the blueprint path.
#
# Run by `task repo:admin-audience-mapping`, which `task repo:lint` -> `task ci`
# runs in CI. See docs/architecture/oidc-integration.md §3.1/§8.
#
# Exit codes: 0 = attached to exactly the admin provider, 1 = drift.
set -euo pipefail

exec "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/check-scope-mapping-provider.sh" \
  "admin-audience" \
  "scope-admin-audience" \
  "BeekeepingIT OAuth Mapping: admin issuer+audience (beekeepingit)" \
  "provider-beekeepingit-admin" \
  "$@"
