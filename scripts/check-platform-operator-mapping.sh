#!/usr/bin/env bash
# Guard: the platform-operator claim mapping must be attached to ONLY the admin
# provider (#465, EPIC-18 #463, NFR-SEC-1, NFR-ROL-1).
#
# The Authentik blueprint defines a scope mapping `scope-platform-operator` whose
# expression emits `platform_operator: true|false` from the caller's REAL
# `platform-operator` group membership. That claim is what lets the services
# (#466) grant cross-tenant, every-organization authority — so ANY oauth2provider
# that references it in its `property_mappings` starts minting tokens that can
# carry platform authority. Attaching it to the PWA provider would put that
# authority on a field-app token (an offline-capable, long-lived credential on a
# beekeeper's phone) — exactly what #465's acceptance criteria forbid. This check
# fails unless EXACTLY the `provider-beekeepingit-admin` entry references it.
#
# The assertion itself lives in scripts/check-scope-mapping-provider.sh (shared
# with the #460 admin-audience guard); this wrapper only pins the mapping this
# repo must guard. An optional argument overrides the blueprint path.
#
# Run by `task repo:platform-operator-mapping`, which `task repo:lint` -> `task ci`
# runs in CI. See docs/architecture/oidc-integration.md §3.2/§8.
#
# Exit codes: 0 = attached to exactly the admin provider, 1 = drift.
set -euo pipefail

exec "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/check-scope-mapping-provider.sh" \
  "platform-operator" \
  "scope-platform-operator" \
  "BeekeepingIT OAuth Mapping: platform-operator membership" \
  "provider-beekeepingit-admin" \
  "$@"
