#!/usr/bin/env bash
# Guard: every upstream federation source in the Authentik blueprint must keep
# the account posture #363 shipped and #364 extended (FR-TEN-1, NFR-SEC-1, D-7).
#
# Adding a federation source hands an EXTERNAL identity provider a path into
# accounts on this deployment. Five properties make that safe, and all five
# are one careless line away from being lost — so they are asserted here rather
# than left to review:
#
#   1. `enrollment_flow` is EXACTLY the dedicated source-enrollment flow
#      (#365: `!KeyOf flow-source-enrollment`). Self-service registration via
#      an upstream is deliberately OPEN — but only through that one flow,
#      whose write path the resolver (3) feeds. Any other flow — or an opaque
#      `!Find` — could write upstream-authored properties, so only the
#      `!KeyOf` spelling passes. Both of that flow's gates are pinned too, by
#      POLICY ID and by the load-bearing term of each expression: the SSO-only
#      policy on the flow (keeps a browser out) and the write guard on its
#      `user_write` binding (keeps a non-resolver-shaped plan from creating an
#      account). Asserting only that "a binding exists" would let an
#      always-true policy read as a gate (auth.md §8.13/§8.15).
#   1b. `authentication_flow` is EXACTLY the source-authentication flow this
#      blueprint OWNS (#594: `!KeyOf flow-source-authentication`), and that flow
#      carries its login stage, its SSO gate and NOTHING ELSE. Two properties
#      ride on this. First, DETERMINISM: the previous spelling — an `!Find` at
#      authentik's bundled `default-source-authentication` — depended on
#      another blueprint file having applied first, which nothing orders, and
#      `Find.resolve` returns None SILENTLY for an optional FK. The source then
#      shipped with a null authentication flow, permanently, and only 400ed
#      ("Configured flow does not exist.") two steps later. `!KeyOf` resolves
#      inside the file and RAISES, so a genuinely missing flow is loud. Second,
#      WRITE SAFETY: that flow must contain a user_login stage and no other —
#      above all no `user_write`, which is what stops a RETURNING federated
#      login overwriting the local `email`, `attributes.upn` or
#      `attributes.email_verified`. An opaque `!Find` could resolve to any flow
#      at all, including one that writes.
#   2. `user_matching_mode: username_link` — and ONLY in combination with (3).
#      Read that as "the matcher looks the account up by its UNIQUE key", not
#      as "trust the upstream's username": #364's property mapping REPLACES the
#      username property with the local account it resolved, or removes it.
#      `username` is the only matchable property `User` declares UNIQUE, so the
#      matcher's `matching_objects.first()` can never pick an arbitrary account
#      out of several (authentik/core/sources/matcher.py). Every other mode is
#      rejected: `identifier` can only ever ENROLL an unlinked identity (#363's
#      dead end), and any `email_*` mode matches the RAW upstream email — which
#      for Google is unverified, because `GoogleType.get_base_user_properties`
#      drops `verified_email`. That is the #170 account-takeover shape.
#   3. The #364 account-resolution property mapping is attached, by `!KeyOf`,
#      and it is the ONLY property mapping on the source. It is what makes (2)
#      safe: it refuses unless the upstream's own verification signal is
#      strictly `True` and exactly one local, active, non-superuser,
#      locally-verified account claims that address (current address or
#      known-email history). Detach it and Google — which emits no `username`
#      at all — DENIES every login (fail closed); detach it from a source type
#      that DOES emit a username and the upstream would choose the account. A
#      second mapping could re-set `username` after it (mappings merge in name
#      order), so exactly one is required.
#   4. Credentials by `!Env`, never literals. The blueprint is rendered into a
#      ConfigMap, so a literal (or Helm-interpolated) client secret would be
#      readable by anything in the namespace and visible in
#      `helm get manifest`. Credentials arrive as process env from the
#      out-of-band Secret merged into `beekeepingit-authentik-config`
#      (charts/authentik/templates/config-secret.yaml).
#
# Plus three structural properties the above depend on:
#   5. Every source entry is `conditions:`-gated, so a cluster without those
#      credentials skips the entry instead of failing serializer validation —
#      which would invalidate the WHOLE blueprint (the PR #414 failure mode).
#   6. The default identification stage is never left with EMPTY `user_fields`,
#      which would trip authentik's AutoRedirectController and send every login
#      to a source with no way to reach the password form.
#   7. The brand PINS `flow_authentication` (#594). Owning a second
#      `designation: authentication` flow in (1b) put this in play:
#      `ToDefaultFlow.get_flow` uses `brand.flow_authentication` when set and
#      otherwise scans authentication flows ORDERED BY SLUG for the first whose
#      policies pass — and `beekeepingit-source-authentication` sorts ahead of
#      `default-authentication-flow`. With the pin, the fallback never runs;
#      without it, (1b)'s SSO gate is all that keeps the login page on the
#      password flow.
#
#   8. The OAuth2 providers reach `signing_key`, `authorization_flow` and
#      `invalidation_flow` by `!KeyOf` at the three IDENTIFIERS-ONLY pin entries,
#      never by `!Find` (#599). `signing_key` is the one field of the three a
#      null actually SURVIVES — `OAuth2ProviderSerializer` has it
#      `required=False, allow_null=True` at 2026.5.4, where the two flows are
#      `required=True, allow_null=False` — so an `!Find` that lost its race left
#      the provider with NO RS256 key: `jwt_key` falls back to
#      `(client_secret, HS256)` and the JWKS serves `{}`, breaking every relying
#      party that verifies signatures. The pins make a missing target raise
#      instead: with no `attrs` a CREATE can never validate (`FlowSerializer`
#      requires name/title/designation, `CertificateKeyPairSerializer` requires
#      `certificate_data`), so the file is recorded ERROR, stores no
#      `last_applied_hash`, and is retried. The absence of `attrs` is therefore
#      load-bearing and is asserted; on the certificate it is ALSO what keeps a
#      private key out of the ConfigMap, which is asserted file-wide.
#
# Deterministic and offline: asserts over the blueprint SOURCE, with no cluster
# and no YAML parser (the file carries custom `!KeyOf`/`!Find`/`!Env` tags a
# plain parser would reject). Same engine style as
# scripts/check-scope-mapping-provider.sh.
#
# The dev/CI stand-in source is held to the SAME bar on purpose: it exists to
# exercise the identical code path, so it must carry the identical posture.
#
# Run by `task repo:federation-source-posture` -> `task repo:lint` -> `task ci`.
# An optional argument overrides the blueprint path.
#
# Exit codes: 0 = posture intact, 1 = drift.
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
blueprint="${1:-${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml}"

# The blueprint id of #364's account-resolution property mapping. Kept as one
# named value because both the per-source assertion and the "it exists at all"
# END check key off it.
link_mapping_id="mapping-federation-account-link"
# The blueprint id of #365's source-enrollment flow — same double duty.
enroll_flow_id="flow-source-enrollment"
# #594's source-AUTHENTICATION flow: the one a RETURNING federated identity is
# signed in through. Owned by the blueprint (not `!Find`-ed at authentik's
# bundled `default-source-authentication`) so it cannot race the default
# blueprints and land null, and so its stage list is ours to pin.
auth_flow_id="flow-source-authentication"
auth_flow_login_stage_id="stage-source-authentication-login"
auth_flow_sso_policy_id="policy-source-authentication-sso-only"
# The DEFAULT (password) authentication flow, and the brand field that pins it.
# Owning a second `designation: authentication` flow (above) put this in play:
# `ToDefaultFlow.get_flow` uses `brand.flow_authentication` when set and otherwise
# scans authentication flows ORDERED BY SLUG, taking the first whose policies pass
# — and `beekeepingit-source-authentication` sorts before `default-authentication-flow`.
default_flow_id="flow-default-authentication"
# ...and its two gates. Asserting the BINDINGS EXIST is not enough: a binding
# carrying a different (or always-true) policy would read as "gated" while
# gating nothing, so both the bound policy IDS and the load-bearing terms of
# their expressions are pinned here — the same rigor assertion (3) applies to
# the #364 resolver, which is checked by id rather than by "a mapping exists".
sso_policy_id="policy-source-enrollment-sso-only"
write_guard_policy_id="policy-source-enrollment-write-guard"
write_binding_id="binding-source-enrollment-user-write"
# #599: the three IDENTIFIERS-ONLY pin entries the OAuth2 providers reference, and
# the objects they name. They declare nothing — authentik creates all three
# itself (the two flows from its bundled blueprint files, the certificate from
# `authentik/crypto/apps.py` at BOOT) — so their only job is to turn a missing
# target into a recorded, retried error instead of a silent null.
authz_flow_pin_id="flow-default-provider-authorization"
authz_flow_slug="default-provider-authorization-implicit-consent"
inval_flow_pin_id="flow-default-provider-invalidation"
inval_flow_slug="default-provider-invalidation-flow"
signing_key_pin_id="cert-authentik-self-signed"
signing_key_name="authentik Self-signed Certificate"

if [ ! -f "${blueprint}" ]; then
  printf '✗ [federation-source] blueprint not found: %s\n' "${blueprint}" >&2
  exit 1
fi

# Walk the blueprint entry-by-entry. Top-level entries begin at `  - model:`;
# everything until the next one is that entry's body, joined into a single
# space-separated string so a value a reformat wrapped across lines still
# matches. Assertions run per entry in flush().
awk -v MAPPING="${link_mapping_id}" -v ENROLL_FLOW="${enroll_flow_id}" \
    -v SSO_POLICY="${sso_policy_id}" -v WRITE_GUARD="${write_guard_policy_id}" \
    -v WRITE_BINDING="${write_binding_id}" -v AUTH_FLOW="${auth_flow_id}" \
    -v AUTH_LOGIN_STAGE="${auth_flow_login_stage_id}" \
    -v AUTH_SSO_POLICY="${auth_flow_sso_policy_id}" \
    -v DEFAULT_FLOW="${default_flow_id}" \
    -v AUTHZ_PIN="${authz_flow_pin_id}" -v AUTHZ_SLUG="${authz_flow_slug}" \
    -v INVAL_PIN="${inval_flow_pin_id}" -v INVAL_SLUG="${inval_flow_slug}" \
    -v KEY_PIN="${signing_key_pin_id}" -v KEY_NAME="${signing_key_name}" '
  # An SSO gate is only a gate while its expression is EXACTLY `return
  # ak_is_sso_flow`. Comments are already stripped, and `expression: |` is the
  # last key of both policy entries, so the whole block is the tail of `body` —
  # anchoring on `$` rejects `return ak_is_sso_flow or True`, which the previous
  # substring test happily accepted (review finding).
  function sso_expression_intact() {
    return body ~ /expression[[:space:]]*:[[:space:]]*[|][[:space:]]*return[[:space:]]+ak_is_sso_flow[[:space:]]*$/
  }

  # Both boundaries matter. The right one stops `!KeyOf x` matching a longer id
  # `x-typo`; the left one stops a longer KEY ENDING IN this one from satisfying
  # it — `jwt_signing_key: !KeyOf …` must not read as `signing_key` set — while a
  # flow-style `{..., a: b,signing_key: !KeyOf c}` must still be seen (same
  # reasoning as assertion (1) below, which spells its own boundary out).
  function keyof(field, target,   pattern) {
    pattern = "(^|[^A-Za-z0-9_-])" field "[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" target "([^A-Za-z0-9_-]|$)"
    return body ~ pattern
  }

  # How many times this entry DECLARES a key. Presence is not enough on its own:
  # PyYAML (authentik`s `BlueprintLoader`) takes LAST-WINS on a duplicate mapping
  # key and raises nothing, so `signing_key: !KeyOf …` followed by
  # `signing_key: null` would satisfy keyof() while shipping the very null this
  # guard exists to prevent (review finding, both reviewers).
  function key_count(field) {
    return gsub("(^|[^A-Za-z0-9_-])" field "[[:space:]]*:", "&", body)
  }

  # An entry that declares NOTHING but its identifiers. That is what makes a pin
  # loud: with no attrs, a CREATE of the named object can never validate, so a
  # missing target raises instead of being invented. See assertion (8).
  function has_attrs() {
    return body ~ /(^|[^A-Za-z0-9_-])attrs[[:space:]]*:/
  }

  function pin_ok(pin_id, key, value,   ok) {
    ok = 1
    # Anchored INSIDE the flow-style `identifiers: { … }` block, not merely
    # somewhere in the entry: an entry could otherwise identify a different
    # object and carry the expected slug under an unrelated key.
    if (body !~ ("identifiers[[:space:]]*:[[:space:]]*[{][^}]*(^|[^A-Za-z0-9_-])" key "[[:space:]]*:[[:space:]]*[\"]?" value "([^A-Za-z0-9_.-]|$)")) {
      printf("✗ [federation-source] pin entry `%s` must identify its target with `identifiers: { %s: %s }` — that is the object authentik itself creates and the providers resolve through it (#599)\n", pin_id, key, value) > "/dev/stderr"
      ok = 0
    }
    if (has_attrs()) {
      printf("✗ [federation-source] pin entry `%s` must carry NO `attrs:` — the absence of attrs is what makes a missing target LOUD (with attrs, a create could validate and invent a stub object instead of raising), and on the certificate it is also what keeps a private key out of the ConfigMap (#599)\n", pin_id) > "/dev/stderr"
      ok = 0
    }
    # `model`, `id`, `identifiers` and nothing else. `state:` above all: `absent`
    # would DELETE authentik`s boot-created certificate, and
    # `OAuth2Provider.signing_key` is `on_delete=SET_NULL` (review finding).
    if (body ~ /(^|[^A-Za-z0-9_-])state[[:space:]]*:/) {
      printf("✗ [federation-source] pin entry `%s` must carry no `state:` — a pin exists only to RESOLVE an object authentik owns; `absent` would DELETE it (and `signing_key` is `on_delete=SET_NULL`), and any other state changes what an identifiers-only entry means (#599)\n", pin_id) > "/dev/stderr"
      ok = 0
    }
    return ok
  }

  function flush() {
    if (model == "") return

    if (model ~ /^authentik_sources_oauth[.]oauthsource$/) {
      sources++
      seen_ids = seen_ids " " id

      # (1) enrollment_flow must be EXACTLY `!KeyOf flow-source-enrollment`
      # (#365). The boundary is a NON-identifier character (not just
      # whitespace) so a flow-style mapping — valid YAML, and a bypass found
      # in review — is caught too:
      #   attrs: {..., authentication_flow: x,enrollment_flow: !KeyOf y}
      # A leading identifier char still excludes an unrelated longer key such
      # as `pre_enrollment_flow:`. `!KeyOf` (never `!Find`) so the flow is
      # provably THE one defined in this file, with its SSO gate and guarded
      # write stage — an opaque reference could resolve to any flow.
      if (body !~ ("(^|[^A-Za-z0-9_-])enrollment_flow[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" ENROLL_FLOW "([^A-Za-z0-9_-]|$)")) {
        printf("✗ [federation-source] %s must set `enrollment_flow: !KeyOf %s` — self-service registration via the upstream (#365) is open ONLY through that dedicated, SSO-gated flow; absent, different or `!Find`-resolved flows all fail this posture\n", id, ENROLL_FLOW) > "/dev/stderr"
        status = 1
      }

      # (1b) authentication_flow must be EXACTLY `!KeyOf
      # flow-source-authentication` (#594) — the flow this file owns, never an
      # `!Find` at an upstream slug. `!Find` resolves to None SILENTLY when the
      # blueprint that owns that slug has not applied yet (nothing orders the
      # two), and `authentication_flow` is an OPTIONAL FK, so the entry still
      # validates and the source ships with NO authentication flow — a hard
      # failure two steps later ("Configured flow does not exist.") that no
      # BlueprintInstance reports. Same boundary regex reasoning as (1).
      if (body !~ ("(^|[^A-Za-z0-9_-])authentication_flow[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" AUTH_FLOW "([^A-Za-z0-9_-]|$)")) {
        printf("✗ [federation-source] %s must set `authentication_flow: !KeyOf %s` — an `!Find` at authentik`s bundled `default-source-authentication` races its own default blueprints and resolves to NULL silently (#594), and an opaque flow reference could point at a flow that WRITES to the user\n", id, AUTH_FLOW) > "/dev/stderr"
        status = 1
      }

      # (2) matching must resolve through the UNIQUE username key, never the
      # raw upstream email (see the header). Anything but `username_link` fails.
      if (body !~ /user_matching_mode[[:space:]]*:[[:space:]]*username_link([^A-Za-z0-9_-]|$)/) {
        printf("✗ [federation-source] %s must set `user_matching_mode: username_link` — it is the only matchable property authentik declares UNIQUE, so the #364 resolver can steer the match to exactly one account; any email_* mode matches the RAW upstream email (unverified for Google — the #170 shape) and `identifier` can never link an unlinked identity\n", id) > "/dev/stderr"
        status = 1
      }

      # (3) the #364 resolver must be attached — by `!KeyOf`, and alone. Same
      # fail-closed-on-the-opaque posture as check-scope-mapping-provider.sh: a
      # `!Find` here could resolve to something this guard cannot reason about,
      # and a SECOND mapping (they merge in name order) could re-set `username`
      # after the resolver cleared it.
      if (body !~ ("user_property_mappings[[:space:]]*:[[:space:]]*[[-]?[[:space:]]*!KeyOf[[:space:]]+" MAPPING "([^A-Za-z0-9_-]|$)")) {
        printf("✗ [federation-source] %s must attach the #364 account-resolution mapping as `user_property_mappings: [!KeyOf %s]` — without it the source either DENIES every login (Google emits no username) or lets the UPSTREAM choose the local account\n", id, MAPPING) > "/dev/stderr"
        status = 1
      }
      n = gsub(/!KeyOf/, "&", body)
      if (n != 3) {
        printf("✗ [federation-source] %s carries %d `!KeyOf` references — a source entry must carry exactly three (the #364 resolver, the #365 enrollment flow and the #594 source-authentication flow). A second property mapping merges AFTER the resolver (name order) and could re-set `username`; if this is a deliberate addition, teach this guard about it in the same change\n", id, n) > "/dev/stderr"
        status = 1
      }

      # (4) credentials must never be literals. consumer_key is exempt only
      # when it is a non-secret public client id AND consumer_secret is !Env
      # (the dev/CI stand-in, which authenticates against nothing).
      if (body !~ /consumer_secret[[:space:]]*:[[:space:]]*!Env[[:space:]]*\[/) {
        printf("✗ [federation-source] %s must take `consumer_secret` from `!Env` — the blueprint renders into a ConfigMap, so a literal or Helm-interpolated secret is readable namespace-wide\n", id) > "/dev/stderr"
        status = 1
      }

      # (5) the entry must be conditions-gated, so an environment without the
      # credentials skips it rather than failing validation for the whole file.
      if (body !~ /(^|[^A-Za-z0-9_-])conditions[[:space:]]*:/) {
        printf("✗ [federation-source] %s has no `conditions:` gate — an environment without its credentials would fail serializer validation and invalidate the ENTIRE blueprint (PR #414)\n", id) > "/dev/stderr"
        status = 1
      }
    }

    # --- (8) #599: the OAuth2 providers` three cross-file references ---------
    # Every provider must reach all three through the pin entries, by `!KeyOf`.
    # `!Find` is rejected outright (see the file-wide rule near the bottom): for
    # `signing_key` it resolved to a SILENT null — `OAuth2ProviderSerializer` has
    # that field `required=False, allow_null=True` at 2026.5.4 — leaving the
    # provider with no RS256 key, an HS256 fallback and an EMPTY JWKS. The two
    # flows are `required=True` there, so their null was already rejected; they
    # are pinned too because that loudness is upstream`s serializer choice, not a
    # property of this file, and a future relaxation would turn them silent with
    # nothing here noticing.
    if (model ~ /^authentik_providers_oauth2[.]oauth2provider$/) {
      providers++
      if (first_provider_line == 0) first_provider_line = entry_line
      # Each field EXACTLY once — see key_count(): a duplicate key is last-wins
      # in PyYAML and would silently override the pin with a null.
      if (key_count("signing_key") != 1 || key_count("authorization_flow") != 1 || key_count("invalidation_flow") != 1) {
        printf("✗ [federation-source] provider `%s` must declare `signing_key`, `authorization_flow` and `invalidation_flow` EXACTLY once each (found %d, %d, %d) — YAML takes the LAST of a duplicate key with no error, so a second declaration silently overrides the pin (#599)\n", id, key_count("signing_key"), key_count("authorization_flow"), key_count("invalidation_flow")) > "/dev/stderr"
        status = 1
      }
      if (!keyof("signing_key", KEY_PIN)) {
        printf("✗ [federation-source] provider `%s` must set `signing_key: !KeyOf %s` — an `!Find` at the certificate races authentik`s BOOT-time `crypto/apps.py` reconcile and resolves to a SILENT null (the field is nullable at the serializer), which drops the provider to HS256 and serves an empty JWKS, breaking every relying party that verifies signatures (#599)\n", id, KEY_PIN) > "/dev/stderr"
        status = 1
      }
      if (!keyof("authorization_flow", AUTHZ_PIN)) {
        printf("✗ [federation-source] provider `%s` must set `authorization_flow: !KeyOf %s` — the pin entry names the flow authentik`s own bundled blueprint creates, and nothing orders that file against this one (#599)\n", id, AUTHZ_PIN) > "/dev/stderr"
        status = 1
      }
      if (!keyof("invalidation_flow", INVAL_PIN)) {
        printf("✗ [federation-source] provider `%s` must set `invalidation_flow: !KeyOf %s` — same cross-file race, same spelling (#599)\n", id, INVAL_PIN) > "/dev/stderr"
        status = 1
      }
    }
    # ...and the three pin entries themselves: right model, right identifier, and
    # NO attrs (see pin_ok — the absence of attrs is the loudness mechanism).
    if (model ~ /^authentik_flows[.]flow$/ && id == AUTHZ_PIN) {
      authz_pins++
      last_pin_line = (entry_line > last_pin_line ? entry_line : last_pin_line)
      if (!pin_ok(AUTHZ_PIN, "slug", AUTHZ_SLUG)) status = 1
    }
    if (model ~ /^authentik_flows[.]flow$/ && id == INVAL_PIN) {
      inval_pins++
      last_pin_line = (entry_line > last_pin_line ? entry_line : last_pin_line)
      if (!pin_ok(INVAL_PIN, "slug", INVAL_SLUG)) status = 1
    }
    if (model ~ /^authentik_crypto[.]certificatekeypair$/ && id == KEY_PIN) {
      key_pins++
      last_pin_line = (entry_line > last_pin_line ? entry_line : last_pin_line)
      if (!pin_ok(KEY_PIN, "name", KEY_NAME)) status = 1
    }

    # #599: fail closed on any `!Find` that reaches one of the three PINNED
    # objects — the "revert to `!Find`" mutation in one line, and it must fail
    # even on a field that is not one of the three (a stray `!Find` at the
    # certificate anywhere is the same silent-null risk). Evaluated against the
    # JOINED entry body rather than per line, because the file already wraps long
    # `!Find [` calls across several lines and a line-scoped rule reads none of
    # them (review finding). `[^]]*` keeps the match inside the tag`s own
    # argument list.
    if (body ~ /!Find[^]]*(certificatekeypair|default-provider-authorization|default-provider-invalidation)/) {
      printf("✗ [federation-source] entry `%s` (model %s) reaches a PINNED object (the self-signed certificate or a provider flow) with `!Find` — `Find.resolve` returns None silently when the target has not been created yet, and for `signing_key` the serializer ACCEPTS that null: HS256 and an empty JWKS, permanently. Use `!KeyOf` at the pin entry (#599)\n", (id == "" ? "<no id>" : id), model) > "/dev/stderr"
      status = 1
    }
    # ...and the same for any object THIS FILE defines (#594). Every per-entry
    # assertion above reasons about `!KeyOf` spellings, so an entry reaching one
    # of our own flows/stages/policies by `!Find` is invisible to them — a real
    # bypass: a `user_write` stage bound with
    # `target: !Find [authentik_flows.flow, [slug, beekeepingit-source-authentication]]`
    # passed the "login-stage-only" assertion. It is also always a bug on its own
    # terms: the entry is right here, so `!KeyOf` is available, deterministic and
    # loud, while `!Find` is order-dependent and silently null.
    if (body ~ /!Find[^]]*beekeepingit-source-/) {
      printf("✗ [federation-source] entry `%s` (model %s) reaches an object this blueprint DEFINES (`beekeepingit-source-*`) with `!Find` — use `!KeyOf <entry id>`: it resolves in-file, raises instead of yielding a silent null (#594), and is the only spelling the assertions in this guard can reason about\n", (id == "" ? "<no id>" : id), model) > "/dev/stderr"
      status = 1
    }

    # The #364 resolver entry itself must exist, exactly once, and be an OAuth
    # SOURCE property mapping (the model the source M2M accepts — a scope
    # mapping with the same id would resolve to nothing usable).
    if (model ~ /^authentik_sources_oauth[.]oauthsourcepropertymapping$/ && id == MAPPING) {
      link_mappings++
    }

    # The #365 source-enrollment flow must exist, exactly once, as a real flow
    # entry (assertion (1) references it by `!KeyOf`, which the importer
    # resolves against ids in THIS file).
    if (model ~ /^authentik_flows[.]flow$/ && id == ENROLL_FLOW) {
      enroll_flows++
    }

    # --- #594: the brand must PIN the default authentication flow ------------
    # Owning a second `designation: authentication` flow makes the brand field
    # load-bearing (see its declaration above). `!KeyOf` so a missing flow raises
    # rather than writing the null that re-arms the slug-ordered fallback.
    if (model ~ /^authentik_brands[.]brand$/) {
      brands++
      if (!keyof("flow_authentication", DEFAULT_FLOW)) {
        printf("✗ [federation-source] the brand entry must set `flow_authentication: !KeyOf %s` — otherwise `ToDefaultFlow` falls back to scanning authentication flows BY SLUG, and `beekeepingit-source-authentication` sorts ahead of `default-authentication-flow`, leaving its SSO gate as the only thing keeping the login page on the right flow (#594)\n", DEFAULT_FLOW) > "/dev/stderr"
        status = 1
      }
    }
    if (model ~ /^authentik_flows[.]flow$/ && id == DEFAULT_FLOW) {
      default_flows++
      if (body !~ /slug[[:space:]]*:[[:space:]]*default-authentication-flow([^A-Za-z0-9_-]|$)/) {
        printf("✗ [federation-source] `%s` must identify the flow with `slug: default-authentication-flow` — it is what the brand pin above resolves to (#594)\n", DEFAULT_FLOW) > "/dev/stderr"
        status = 1
      }
    }

    # --- #594: the source-AUTHENTICATION flow, and its complete stage list ---
    # The flow entry itself must exist exactly once (assertion (1b) references
    # it by `!KeyOf`, which the importer resolves against ids in THIS file).
    if (model ~ /^authentik_flows[.]flow$/ && id == AUTH_FLOW) {
      auth_flows++
      # The whole justification for owning this flow is that it REPRODUCES
      # upstream`s `default-source-authentication` shape. A blueprint id does not
      # pin that, so the three security-relevant attributes are pinned here: the
      # slug the probe asserts on the deployed source, the designation that makes
      # it an authentication flow at all, and the requirement that keeps an
      # already-authenticated session out of it.
      if (body !~ /slug[[:space:]]*:[[:space:]]*beekeepingit-source-authentication([^A-Za-z0-9_-]|$)/) {
        printf("✗ [federation-source] `%s` must keep `slug: beekeepingit-source-authentication` — that slug is what infra/ci/authentik-federation-probe.py asserts on the DEPLOYED source (#594)\n", AUTH_FLOW) > "/dev/stderr"
        status = 1
      }
      if (body !~ /designation[[:space:]]*:[[:space:]]*authentication([^A-Za-z0-9_-]|$)/) {
        printf("✗ [federation-source] `%s` must keep `designation: authentication` — `SourceFlowManager` plans it as the sign-in flow for a returning federated identity (#594)\n", AUTH_FLOW) > "/dev/stderr"
        status = 1
      }
      if (body !~ /authentication[[:space:]]*:[[:space:]]*require_unauthenticated([^A-Za-z0-9_-]|$)/) {
        printf("✗ [federation-source] `%s` must keep `authentication: require_unauthenticated` — upstream`s flow sets it, and it is the second, independent layer keeping an authenticated session out of a source sign-in (#594)\n", AUTH_FLOW) > "/dev/stderr"
        status = 1
      }
    }
    # Its login stage, likewise owned here: an `!Find` at authentik`s own
    # `default-authentication-login` would put the very race (1b) removes right
    # back into the flow.
    if (model ~ /^authentik_stages_user_login[.]userloginstage$/ && id == AUTH_LOGIN_STAGE) {
      auth_login_stages++
    }
    # EVERY stage binding on that flow must be the login stage. This is the
    # write-safety property stated structurally: a `user_write` (or any other)
    # stage bound here would let a RETURNING federated login overwrite the local
    # `email`, `attributes.upn` or `attributes.email_verified` — the thing #363,
    # #364 and #365 each rely on this flow NOT doing.
    if (model ~ /^authentik_flows[.]flowstagebinding$/ && keyof("target", AUTH_FLOW)) {
      if (keyof("stage", AUTH_LOGIN_STAGE)) {
        auth_flow_login_bindings++
      } else {
        printf("✗ [federation-source] a flow-stage binding targets `%s` with a stage OTHER than `%s` — that flow must carry the login stage and NOTHING else; any additional stage (a `user_write` above all) would let a returning federated login overwrite the local email/upn/email_verified\n", AUTH_FLOW, AUTH_LOGIN_STAGE) > "/dev/stderr"
        status = 1
      }
    }
    # ...and it is SSO-gated, exactly like the enrollment flow: same
    # fail-closed-on-the-opaque posture, an unrecognized policy is an error.
    if (model ~ /^authentik_policies[.]policybinding$/ && keyof("target", AUTH_FLOW)) {
      if (keyof("policy", AUTH_SSO_POLICY)) {
        auth_flow_gates++
      } else {
        printf("✗ [federation-source] a policy binding targets `%s` with a policy OTHER than `%s` — that flow`s only gate is the SSO-only policy, and an unrecognized one cannot be reasoned about here\n", AUTH_FLOW, AUTH_SSO_POLICY) > "/dev/stderr"
        status = 1
      }
    }
    if (model ~ /^authentik_policies_expression[.]expressionpolicy$/ && id == AUTH_SSO_POLICY) {
      auth_sso_policies++
      if (!sso_expression_intact()) {
        printf("✗ [federation-source] `%s` is no longer EXACTLY `expression: |` followed by `return ak_is_sso_flow` — that expression IS the gate keeping a browser out of the source-authentication flow, and a substring test would pass `return ak_is_sso_flow or True` (#594)\n", AUTH_SSO_POLICY) > "/dev/stderr"
        status = 1
      }
    }

    # GATE 1 — the flow itself is SSO-only, so a browser cannot enter it
    # outside a federated sign-in. Asserting the POLICY, not merely that some
    # binding exists: a binding carrying an unrelated policy would still read
    # as "gated". An unrecognized policy on this flow is an error rather than
    # a pass, the same fail-closed-on-the-opaque posture as assertion (3).
    if (model ~ /^authentik_policies[.]policybinding$/ && keyof("target", ENROLL_FLOW)) {
      if (keyof("policy", SSO_POLICY)) {
        enroll_flow_gates++
      } else {
        printf("✗ [federation-source] a policy binding targets `%s` with a policy OTHER than `%s` — the enrollment flow`s only gate is the SSO-only policy, and an unrecognized one cannot be reasoned about here; if this is a deliberate addition, teach this guard about it in the same change\n", ENROLL_FLOW, SSO_POLICY) > "/dev/stderr"
        status = 1
      }
    }

    # GATE 2 — the write guard is bound to the user_write binding, so a plan
    # that is not resolver-shaped creates no account. Same reasoning as above.
    if (model ~ /^authentik_policies[.]policybinding$/ && keyof("target", WRITE_BINDING)) {
      if (keyof("policy", WRITE_GUARD)) {
        write_binding_gates++
      } else {
        printf("✗ [federation-source] a policy binding targets `%s` with a policy OTHER than `%s` — that binding`s only gate is the write guard (#365)\n", WRITE_BINDING, WRITE_GUARD) > "/dev/stderr"
        status = 1
      }
    }

    # Both gate policies must exist AND still carry their load-bearing test.
    # An expression edited to `return True` would otherwise keep every
    # structural assertion above green while gating nothing.
    if (model ~ /^authentik_policies_expression[.]expressionpolicy$/ && id == SSO_POLICY) {
      sso_policies++
      if (!sso_expression_intact()) {
        printf("✗ [federation-source] `%s` is no longer EXACTLY `expression: |` followed by `return ak_is_sso_flow` — that expression IS the gate keeping a browser out of the enrollment flow, and a substring test would pass `return ak_is_sso_flow or True` (#365)\n", SSO_POLICY) > "/dev/stderr"
        status = 1
      }
    }
    if (model ~ /^authentik_policies_expression[.]expressionpolicy$/ && id == WRITE_GUARD) {
      write_guards++
      if (body !~ /email_verified/ || body !~ /upn/) {
        printf("✗ [federation-source] `%s` no longer checks both `email_verified` and `upn` — those are what make an enrollment write resolver-authored rather than half-formed (#365)\n", WRITE_GUARD) > "/dev/stderr"
        status = 1
      }
    }

    # (6) no identification-stage entry may empty user_fields.
    if (model ~ /^authentik_stages_identification[.]identificationstage$/) {
      ident_entries++
      if (body ~ /user_fields:[[:space:]]*\[[[:space:]]*\]/) {
        printf("✗ [federation-source] an identification-stage entry sets an EMPTY `user_fields` — authentik auto-redirects such a stage to its single source, removing every way to reach the password form\n") > "/dev/stderr"
        status = 1
      }
      if (body !~ /user_fields:/) {
        printf("✗ [federation-source] an identification-stage entry omits `user_fields` — IdentificationStageSerializer cross-validates the entry`s OWN data and would reject it, invalidating the whole blueprint (PR #414)\n") > "/dev/stderr"
        status = 1
      }
    }
  }

  # Strip comments before anything else: the section documentation deliberately
  # names `enrollment_flow` and `email_link`, and must not be assertable text.
  # A YAML comment must be at line start or preceded by whitespace, so the
  # boundary is required — otherwise a legitimate `#` inside a value (a URL
  # fragment, a CSS colour) would be silently truncated, hiding real content
  # from the assertions above (review finding).
  { sub(/(^|[[:space:]])#.*$/, "") }
  /^[[:space:]]*$/ { next }

  # `!Env` MUST use the two-element [VAR, default] form. authentik`s Env tag
  # constructor reads node.value[1] unconditionally for a sequence node, so the
  # one-element `!Env [VAR]` spelling raises IndexError while the file is being
  # PARSED. That kills blueprints_discovery for the WHOLE file: no
  # BlueprintInstance row is created, nothing reports the file as invalid, and
  # the only symptom is OIDC discovery 404ing forever. Cost one 23-minute CI
  # bring-up to diagnose, so it is asserted here in milliseconds. (A structural
  # YAML parse does NOT catch this — the tag constructors only run inside
  # authentik.)
  /!Env[[:space:]]*\[/ {
    if ($0 !~ /!Env[[:space:]]*\[[^]]*,/) {
      printf("✗ [federation-source] line %d uses the one-element `!Env [VAR]` form — authentik raises IndexError parsing it, which silently kills blueprint discovery for the entire file; use `!Env [VAR, \"\"]`\n", FNR) > "/dev/stderr"
      status = 1
    }
  }

  # (The two `!Find` bans — at objects THIS FILE defines, and at the three PINNED
  # objects — live in flush(), asserted against the JOINED entry body: this file
  # already wraps long `!Find [` calls across several lines, and a line-scoped
  # rule reads none of them. #599 review finding.)
  #
  # #599 / NFR-SEC-1: a certificate or private key literal must never appear in
  # this file. It renders into a ConfigMap readable by anything in the namespace
  # — the same reason the source credentials arrive via `!Env` — and it is also
  # what would let the certificate pin CREATE a stub keypair instead of raising.
  # The boundary is a negated identifier class plus an optional punctuation
  # character, rather than "start or whitespace", so a QUOTED key
  # (`"key_data":`) or a flow-mapping one (`{key_data: …}`) cannot slip past it
  # (review finding).
  /(^|[^A-Za-z0-9_-])[[:punct:]]?(certificate_data|key_data)[[:punct:]]?[[:space:]]*:/ {
    printf("✗ [federation-source] line %d sets `certificate_data`/`key_data` — this blueprint renders into a ConfigMap, so a certificate or PRIVATE KEY literal here is readable namespace-wide (NFR-SEC-1); the signing certificate is authentik`s own boot-created one, referenced by the `%s` pin (#599)\n", FNR, KEY_PIN) > "/dev/stderr"
    status = 1
  }

  # Fail closed on YAML anchors/aliases/merge keys ANYWHERE in the file. This
  # guard reasons over each entry`s own text and does not resolve anchors, so a
  # `<<: *shared` merge could reintroduce `enrollment_flow` into a source entry
  # from a definition elsewhere and pass assertion (1) unseen. The blueprint
  # has never used anchors; banning them outright is cheaper and more certain
  # than teaching this script to expand them. Same fail-closed-on-the-opaque
  # posture as scripts/check-scope-mapping-provider.sh.
  /(^|[[:space:]])(<<[[:space:]]*:|&[A-Za-z_]|\*[A-Za-z_])/ {
    printf("✗ [federation-source] line %d uses a YAML anchor/alias/merge key — this guard does not resolve them and cannot prove a source entry keeps this posture (e.g. which enrollment flow it references); keep the blueprint anchor-free\n", FNR) > "/dev/stderr"
    status = 1
  }

  /^  - model:/ { flush(); model = $3; id = ""; body = ""; entry_line = FNR; next }
  { body = body " " $0 }
  /^    id:/ { if (id == "") id = $2 }

  END {
    flush()
    if (sources == 0) {
      printf("✗ [federation-source] no oauthsource entry found — #363 shipped one; if it was removed on purpose, remove this guard in the same change\n") > "/dev/stderr"
      status = 1
    }
    if (ident_entries == 0) {
      printf("✗ [federation-source] no identification-stage entry found — the sources would never be shown on the login card\n") > "/dev/stderr"
      status = 1
    }
    if (link_mappings != 1) {
      printf("✗ [federation-source] expected exactly ONE `authentik_sources_oauth.oauthsourcepropertymapping` entry with id `%s`, found %d — it is the #364 account resolver every source above references\n", MAPPING, link_mappings) > "/dev/stderr"
      status = 1
    }
    if (enroll_flows != 1) {
      printf("✗ [federation-source] expected exactly ONE `authentik_flows.flow` entry with id `%s`, found %d — it is the #365 source-enrollment flow every source above references by `!KeyOf`\n", ENROLL_FLOW, enroll_flows) > "/dev/stderr"
      status = 1
    }
    if (enroll_flow_gates != 1) {
      printf("✗ [federation-source] expected exactly ONE `%s` binding targeting `%s`, found %d — the source-enrollment flow must be SSO-gated or a browser could enter it directly, outside any federated sign-in (#365)\n", SSO_POLICY, ENROLL_FLOW, enroll_flow_gates) > "/dev/stderr"
      status = 1
    }
    if (write_binding_gates == 0) {
      printf("✗ [federation-source] no `%s` binding targets `%s` — an unguarded user_write would create an account from whatever the plan happened to carry (#365)\n", WRITE_GUARD, WRITE_BINDING) > "/dev/stderr"
      status = 1
    }
    if (auth_flows != 1 || auth_login_stages != 1 || auth_sso_policies != 1) {
      printf("✗ [federation-source] expected exactly ONE `%s` flow entry, ONE `%s` user-login-stage entry and ONE `%s` expression policy, found %d, %d and %d — they are the #594 source-authentication flow every source above references by `!KeyOf`, and owning all three is what keeps it from racing authentik`s bundled default blueprints\n", AUTH_FLOW, AUTH_LOGIN_STAGE, AUTH_SSO_POLICY, auth_flows, auth_login_stages, auth_sso_policies) > "/dev/stderr"
      status = 1
    }
    if (brands != 1 || default_flows != 1) {
      printf("✗ [federation-source] expected exactly ONE brand entry and ONE `%s` flow entry, found %d and %d — together they pin which flow /flows/-/default/authentication/ resolves to, which owning a second authentication flow put in play (#594)\n", DEFAULT_FLOW, brands, default_flows) > "/dev/stderr"
      status = 1
    }
    if (auth_flow_login_bindings != 1) {
      printf("✗ [federation-source] expected exactly ONE flow-stage binding of `%s` onto `%s`, found %d — without it the flow has no stage to sign the returning identity in with (#594)\n", AUTH_LOGIN_STAGE, AUTH_FLOW, auth_flow_login_bindings) > "/dev/stderr"
      status = 1
    }
    if (auth_flow_gates != 1) {
      printf("✗ [federation-source] expected exactly ONE `%s` binding targeting `%s`, found %d — the source-authentication flow must be SSO-gated or a browser could enter it directly, outside any federated sign-in (#594)\n", AUTH_SSO_POLICY, AUTH_FLOW, auth_flow_gates) > "/dev/stderr"
      status = 1
    }
    if (providers == 0) {
      printf("✗ [federation-source] no `authentik_providers_oauth2.oauth2provider` entry found — the pins below exist to serve them; if the providers moved elsewhere, move assertion (8) with them in the same change (#599)\n") > "/dev/stderr"
      status = 1
    }
    # `!KeyOf` resolves BACKWARDS ONLY: `KeyOf.resolve` scans this file`s entries
    # for one with that id that ALREADY has a model instance, so a pin below its
    # referrer raises and the WHOLE blueprint stays ERROR until someone edits the
    # file. Loud, but only discoverable through a ~23-minute bring-up — assert it
    # here in milliseconds instead (review finding).
    if (last_pin_line > first_provider_line && first_provider_line > 0) {
      printf("✗ [federation-source] a pin entry is declared at line %d, BELOW the first OAuth2 provider at line %d — `!KeyOf` only resolves against entries applied EARLIER in the file, so every reference would raise and the whole blueprint would stay ERROR; keep the pins above the providers (#599)\n", last_pin_line, first_provider_line) > "/dev/stderr"
      status = 1
    }
    if (authz_pins != 1 || inval_pins != 1 || key_pins != 1) {
      printf("✗ [federation-source] expected exactly ONE pin entry each for `%s`, `%s` and `%s`, found %d, %d and %d — they are what every provider above resolves through by `!KeyOf`, and a missing one turns that reference into a hard EntryInvalidError rather than the silent null it replaced (#599)\n", AUTHZ_PIN, INVAL_PIN, KEY_PIN, authz_pins, inval_pins, key_pins) > "/dev/stderr"
      status = 1
    }
    if (sso_policies != 1 || write_guards != 1) {
      printf("✗ [federation-source] expected exactly one `%s` and one `%s` expression policy, found %d and %d — they are the enrollment flow`s two gates (#365)\n", SSO_POLICY, WRITE_GUARD, sso_policies, write_guards) > "/dev/stderr"
      status = 1
    }
    if (status == 0) {
      printf("› [federation-source] ok: %d source(s) [%s ] are resolver-matched (%s), authenticated via %s (SSO-gated, login-stage-only), enrollment-open only via %s (SSO-gated + write-guarded), !Env-credentialed and conditions-gated; %d OAuth2 provider(s) reach signing_key/authorization_flow/invalidation_flow by !KeyOf at the three identifiers-only pins\n", sources, seen_ids, MAPPING, AUTH_FLOW, ENROLL_FLOW, providers)
    }
    exit status
  }
' "${blueprint}"
