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
# `provider-beekeepingit-admin` entry references it: a deterministic, offline
# assertion over the blueprint source (no cluster, no YAML parser needed — the
# blueprint carries custom `!KeyOf`/`!Find` tags a plain parser would reject).
#
# Run by `task repo:admin-audience-mapping`, which `task repo:lint` -> `task ci`
# runs in CI. See docs/architecture/oidc-integration.md §3.1/§8.
#
# Exit codes: 0 = attached to exactly the admin provider, 1 = drift.
set -euo pipefail

# The mapping's blueprint id (the `!KeyOf <id>` reference form), its
# `identifiers.name` (the `!Find [..., [name, "<name>"]]` reference form — the
# idiom the blueprint already uses for every OTHER scope-mapping attachment), and
# the ONLY provider entry allowed to carry it. Both reference forms must be
# guarded: matching only `!KeyOf` would let a rogue provider attach the override
# by name and silently inherit acceptance by every domain service.
mapping_id="scope-admin-audience"
mapping_name="BeekeepingIT OAuth Mapping: admin issuer+audience (beekeepingit)"
allowed_provider_id="provider-beekeepingit-admin"

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
blueprint="${1:-${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml}"

if [ ! -f "${blueprint}" ]; then
  printf '✗ [admin-audience] blueprint not found: %s\n' "${blueprint}" >&2
  exit 1
fi

# Walk the blueprint entry-by-entry (entries begin at a top-level `  - model:`
# list item). Accumulate each entry's whole body into one string (lines joined by
# spaces) so a reference tag that a reformat wrapped across lines still matches.
# For each oauth2provider entry, flag it if that joined body references the
# override mapping by EITHER its `!KeyOf <id>` (matched at a token boundary, so a
# longer id like `<id>-v2` never counts) OR its `!Find`-by-name form (the unique
# mapping name only appears in another entry via a `!Find` reference). Then assert
# the set of referencing providers is exactly {allowed_provider_id}.
awk -v mapping="${mapping_id}" -v mapname="${mapping_name}" -v allowed="${allowed_provider_id}" '
  function flush() {
    if (model == "") return
    # Only oauth2provider entries can attach property_mappings; record which
    # provider ids reference the override mapping, by either reference form.
    if (model ~ /authentik_providers_oauth2\.oauth2provider/) {
      if (body ~ ("!KeyOf[[:space:]]+" mapping "([^A-Za-z0-9_-]|$)") || index(body, mapname) > 0) {
        referencing[id] = 1
      }
    }
  }
  # New top-level entry: flush the previous one, reset per-entry state. The model
  # name is the third field of `  - model: <name>`. The model line itself is not
  # part of the body (next skips the accumulator below).
  /^  - model:/ { flush(); model = $3; id = ""; body = ""; next }
  # Accumulate every other line of the entry into one space-joined string.
  { body = body " " $0 }
  # Capture the entry id (first `id:` line). Also count the mapping DEFINITION
  # (the entry whose own id IS the mapping) to assert it exists exactly once — a
  # reference is `!KeyOf`/`!Find`, never `id:`.
  /^    id:/ {
    if (id == "") id = $2
    if ($2 == mapping) def_count++
  }
  END {
    flush()
    status = 0
    if (def_count != 1) {
      printf("✗ [admin-audience] expected exactly one definition of %s, found %d\n", mapping, def_count) > "/dev/stderr"
      status = 1
    }
    # Every referencing provider must be the allowed one.
    for (p in referencing) {
      if (p != allowed) {
        printf("✗ [admin-audience] %s is attached to provider %s — it may be attached ONLY to %s\n", mapping, p, allowed) > "/dev/stderr"
        status = 1
      }
    }
    # The allowed provider must actually carry it (else the override silently stopped applying).
    if (!(allowed in referencing)) {
      printf("✗ [admin-audience] %s is not attached to %s — the admin token iss/aud override would not apply\n", mapping, allowed) > "/dev/stderr"
      status = 1
    }
    if (status == 0) printf("› [admin-audience] ok: %s is attached to exactly one provider (%s)\n", mapping, allowed)
    exit status
  }
' "${blueprint}"
