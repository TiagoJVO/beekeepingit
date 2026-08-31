#!/usr/bin/env bash
# Guard: every upstream federation source in the Authentik blueprint must keep
# the account posture #363 shipped and #364 extended (FR-TEN-1, NFR-SEC-1, D-7).
#
# Adding a federation source hands an EXTERNAL identity provider a path into
# accounts on this deployment. Four properties make that safe, and all four
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
# Plus two structural properties the above depend on:
#   5. Every source entry is `conditions:`-gated, so a cluster without those
#      credentials skips the entry instead of failing serializer validation —
#      which would invalidate the WHOLE blueprint (the PR #414 failure mode).
#   6. The default identification stage is never left with EMPTY `user_fields`,
#      which would trip authentik's AutoRedirectController and send every login
#      to a source with no way to reach the password form.
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
# ...and its two gates. Asserting the BINDINGS EXIST is not enough: a binding
# carrying a different (or always-true) policy would read as "gated" while
# gating nothing, so both the bound policy IDS and the load-bearing terms of
# their expressions are pinned here — the same rigor assertion (3) applies to
# the #364 resolver, which is checked by id rather than by "a mapping exists".
sso_policy_id="policy-source-enrollment-sso-only"
write_guard_policy_id="policy-source-enrollment-write-guard"
write_binding_id="binding-source-enrollment-user-write"

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
    -v WRITE_BINDING="${write_binding_id}" '
  function keyof(field, target,   pattern) {
    pattern = field "[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" target "([^A-Za-z0-9_-]|$)"
    return body ~ pattern
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
      if (n != 2) {
        printf("✗ [federation-source] %s carries %d `!KeyOf` references — a source entry must carry exactly two (the #364 resolver and the #365 enrollment flow). A second property mapping merges AFTER the resolver (name order) and could re-set `username`; if this is a deliberate addition, teach this guard about it in the same change\n", id, n) > "/dev/stderr"
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
      if (body !~ /ak_is_sso_flow/) {
        printf("✗ [federation-source] `%s` no longer tests `ak_is_sso_flow` — that test IS the gate keeping a browser out of the enrollment flow (#365)\n", SSO_POLICY) > "/dev/stderr"
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

  /^  - model:/ { flush(); model = $3; id = ""; body = ""; next }
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
    if (enroll_flow_gates == 0) {
      printf("✗ [federation-source] no `%s` binding targets `%s` — the source-enrollment flow must be SSO-gated or a browser could enter it directly, outside any federated sign-in (#365)\n", SSO_POLICY, ENROLL_FLOW) > "/dev/stderr"
      status = 1
    }
    if (write_binding_gates == 0) {
      printf("✗ [federation-source] no `%s` binding targets `%s` — an unguarded user_write would create an account from whatever the plan happened to carry (#365)\n", WRITE_GUARD, WRITE_BINDING) > "/dev/stderr"
      status = 1
    }
    if (sso_policies != 1 || write_guards != 1) {
      printf("✗ [federation-source] expected exactly one `%s` and one `%s` expression policy, found %d and %d — they are the enrollment flow`s two gates (#365)\n", SSO_POLICY, WRITE_GUARD, sso_policies, write_guards) > "/dev/stderr"
      status = 1
    }
    if (status == 0) {
      printf("› [federation-source] ok: %d source(s) [%s ] are resolver-matched (%s), enrollment-open only via %s (SSO-gated + write-guarded), !Env-credentialed and conditions-gated\n", sources, seen_ids, MAPPING, ENROLL_FLOW)
    }
    exit status
  }
' "${blueprint}"
