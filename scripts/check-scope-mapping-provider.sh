#!/usr/bin/env bash
# Guard: a security-sensitive Authentik scope mapping must be attached to EXACTLY
# one oauth2provider in the blueprint (#460, #465, NFR-SEC-1).
#
# Generic engine behind the per-mapping wrappers:
#   - scripts/check-admin-audience-mapping.sh   (#456/#460 iss/aud override)
#   - scripts/check-platform-operator-mapping.sh (#465 platform_operator claim)
#
# Both mappings widen a trust boundary for whichever provider carries them — the
# iss/aud override makes a provider's tokens acceptable to every domain service,
# and the platform-operator claim grants cross-tenant platform authority — so
# attaching either to a second provider (e.g. the PWA) must fail CI. This is a
# deterministic, offline assertion over the blueprint SOURCE: no cluster, and no
# YAML parser (the blueprint carries custom `!KeyOf`/`!Find` tags a plain parser
# would reject).
#
# Usage: check-scope-mapping-provider.sh <label> <mapping-id> <mapping-name> \
#          <allowed-provider-id> [blueprint-path]
#
# Exit codes: 0 = attached to exactly the allowed provider, 1 = drift/usage error.
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  printf 'usage: %s <label> <mapping-id> <mapping-name> <allowed-provider-id> [blueprint]\n' \
    "$(basename -- "$0")" >&2
  exit 1
fi

# The mapping's blueprint id (the `!KeyOf <id>` reference form), its
# `identifiers.name` (the `!Find [..., [name, "<name>"]]` reference form — the
# idiom the blueprint already uses for every OTHER scope-mapping attachment), and
# the ONLY provider entry allowed to carry it. Both reference forms must be
# guarded: matching only `!KeyOf` would let a rogue provider attach the mapping
# by name and silently inherit its privilege.
label="$1"
mapping_id="$2"
mapping_name="$3"
allowed_provider_id="$4"

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
blueprint="${5:-${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml}"

if [ ! -f "${blueprint}" ]; then
  printf '✗ [%s] blueprint not found: %s\n' "${label}" "${blueprint}" >&2
  exit 1
fi

# Walk the blueprint entry-by-entry (entries begin at a top-level `  - model:`
# list item). Accumulate each entry's whole body into one string (lines joined by
# spaces) so a reference tag that a reformat wrapped across lines still matches.
# For each oauth2provider entry, flag it if that joined body references the
# guarded mapping by EITHER its `!KeyOf <id>` (matched at a token boundary, so a
# longer id like `<id>-v2` never counts) OR its `!Find`-by-name form (the unique
# mapping name only appears in another entry via a `!Find` reference). Then assert
# the set of referencing providers is exactly {allowed_provider_id}.
#
# Those two forms alone are NOT sufficient, because `!Find` can look a scopemapping
# up by ANY field — `[description, "…"]`, `[pk, …]`, `[scope_name, …]` — and such an
# edit looks unremarkable in a file that already uses `!Find` everywhere (security
# review, #465). So the check is inverted for every provider that is NOT the allowed
# one: on those, the ONLY tolerated way to reference a scopemapping is
# `!Find [..., [managed, …]]` (an upstream built-in, which by definition is not a
# guarded custom mapping) — every custom mapping in this blueprint is attached by
# `!KeyOf`. Any other `!Find` lookup into `authentik_providers_oauth2.scopemapping`
# is OPAQUE to a textual guard, so it fails closed rather than being assumed benign.
# YAML aliases get the same treatment: an alias (`*anchor`) in a provider body could
# expand to the guarded mapping, and this script does not resolve anchors — so any
# alias inside a provider entry fails closed too. (The `.*` in the redirect-URI
# regexes is not an alias: an alias token starts at a word boundary and is followed
# by an identifier.)
awk -v label="${label}" -v mapping="${mapping_id}" -v mapname="${mapping_name}" \
  -v allowed="${allowed_provider_id}" '
  function flush(   probe, total_find, managed_find) {
    if (model == "") return
    # Only oauth2provider entries can attach property_mappings; record which
    # provider ids reference the guarded mapping, by either reference form.
    if (model !~ /authentik_providers_oauth2\.oauth2provider/) return
    if (body ~ ("!KeyOf[[:space:]]+" mapping "([^A-Za-z0-9_-]|$)") || index(body, mapname) > 0) {
      referencing[id] = 1
    }
    if (id == allowed) return

    # --- Non-allowed provider: nothing opaque may reference a scopemapping. ---
    # gsub returns its substitution count, so count total scopemapping !Find
    # lookups and how many of those are the benign `[managed, …]` form.
    probe = body
    total_find = gsub(/!Find[[:space:]]*\[[[:space:]]*authentik_providers_oauth2\.scopemapping/, "", probe)
    probe = body
    managed_find = gsub(/!Find[[:space:]]*\[[[:space:]]*authentik_providers_oauth2\.scopemapping[[:space:]]*,[[:space:]]*\[[[:space:]]*managed[[:space:]]*,/, "", probe)
    if (total_find != managed_find) opaque[id] = total_find - managed_find
    if (body ~ /(^|[[:space:]])\*[A-Za-z_]/) aliased[id] = 1
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
      printf("✗ [%s] expected exactly one definition of %s, found %d\n", label, mapping, def_count) > "/dev/stderr"
      status = 1
    }
    # Every referencing provider must be the allowed one.
    for (p in referencing) {
      if (p != allowed) {
        printf("✗ [%s] %s is attached to provider %s — it may be attached ONLY to %s\n", label, mapping, p, allowed) > "/dev/stderr"
        status = 1
      }
    }
    # The allowed provider must actually carry it (else the mapping silently stopped applying).
    if (!(allowed in referencing)) {
      printf("✗ [%s] %s is not attached to %s — the mapping would not apply\n", label, mapping, allowed) > "/dev/stderr"
      status = 1
    }
    # Anything this textual guard cannot resolve on a non-allowed provider is a
    # potential hiding place for the guarded mapping — fail closed, do not assume.
    for (p in opaque) {
      printf("✗ [%s] provider %s references a scopemapping by an opaque !Find lookup (%d non-`managed` lookup(s)) — this guard cannot prove it is not %s; attach custom mappings with !KeyOf\n", label, p, opaque[p], mapping) > "/dev/stderr"
      status = 1
    }
    for (p in aliased) {
      printf("✗ [%s] provider %s uses a YAML alias — this guard does not resolve anchors and cannot prove the alias is not %s\n", label, p, mapping) > "/dev/stderr"
      status = 1
    }
    if (status == 0) printf("› [%s] ok: %s is attached to exactly one provider (%s)\n", label, mapping, allowed)
    exit status
  }
' "${blueprint}"
