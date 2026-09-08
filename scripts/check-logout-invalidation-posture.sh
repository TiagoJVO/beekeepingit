#!/usr/bin/env bash
# Guard: Sign out must END the provider session AND come back to the app, and
# it must only ever come back to an origin this chart itself renders (#237,
# NFR-SEC-1, FR-ONB, D-7).
#
# Both halves of #237 are one deleted line away from returning, and neither
# failure is loud — the app keeps "logging out", it just stops meaning it:
#
#   1. THE SESSION HALF. Upstream's `default-provider-invalidation-flow` — the
#      `invalidation_flow` of both our providers — ships with NO STAGE BINDINGS
#      (blueprints/default/flow-default-provider-invalidation.yaml @ 2026.5.4).
#      `EndSessionView` deletes the provider's access tokens and appends an
#      in-memory `SessionEndStage`, but nothing ends the authentik SSO session,
#      so `request.user.is_authenticated` is still true when that stage renders
#      and the next "Sign in" completes with NO PASSWORD. auth.md §7 promises
#      the opposite ("revokes the SERVER-SIDE SSO session, not just local
#      tokens"), so the `user_logout` stage bound into that flow is the only
#      thing making the promise true. Asserted by BINDING, not by "a logout
#      stage exists": an unbound stage is decoration. And asserted as a LIVE,
#      SINGLE, REACHABLE binding, because "the text is in the file" is not the
#      same claim (each of these passed the first version of this guard):
#      `state: absent` deletes the entry on apply; `conditions: [false]` leaves
#      the planner skipping it; a duplicate `target:` key silently re-points it
#      (PyYAML is last-wins and raises nothing); a second entry for the same id
#      overrides the one that was read; and repointing BOTH providers'
#      `invalidation_flow` elsewhere leaves the binding intact on a flow neither
#      provider ever plans. So: exactly one stage entry, exactly one binding,
#      no `state:`/`conditions:` on either, exactly one `target:`/`stage:` in
#      the binding, and `invalidation_flow: !KeyOf` the pinned flow declared
#      exactly once in EACH provider.
#
#   2. THE RETURN HALF, AND ITS ALLOW-LIST. `post_logout_redirect_uris` is not
#      a field at 2026.5.4 — it is a PROPERTY over the provider's `redirect_uris`
#      filtered to `redirect_uri_type: logout` (providers/oauth2/models.py), and
#      `EndSessionView.validate` only honours the client's
#      `post_logout_redirect_uri` when that property is NON-EMPTY. Drop the
#      logout-typed entries and the parameter is silently ignored again: the
#      browser stops at the `ak-stage-session-end` interstitial (#237's
#      original symptom) instead of returning to the app.
#
#      Declaring them also makes authentik STRICTLY validate that parameter, so
#      the entries ARE the open-redirect boundary. Each one must therefore name
#      an origin this chart renders — `{{ .Values.global.appOrigin }}` or
#      `{{ .Values.global.adminOrigin }}`, so every environment overlay
#      allow-lists exactly its own hosts and nothing hand-written can drift in
#      — or one of the enumerated localhost DEV PORTS, each a STRICT LITERAL.
#      A literal host, a `.*`, or a bare-origin regex would turn a validated
#      allow-list back into an open redirect while still looking like a list.
#      There is deliberately NO localhost regex here in ANY spelling — that is
#      the owner decision recorded on #822, and each candidate was
#      disqualified by running Python, not by reading the pattern:
#      `http://localhost:.*` fullmatches `http://localhost:@evil.example`,
#      which a browser resolves to host evil.example with `localhost:` as
#      USERINFO; `http://localhost:\d+` allow-lists UNICODE decimal digits
#      (`http://localhost:٤٥` fullmatches) and makes `urlparse(...).port`
#      RAISE inside `cors_allow`, 500ing every localhost `Origin`; and
#      `http://localhost:[0-9]+` is a BRACKETED netloc — see (3). A strict
#      literal carries no metacharacter at all, so it is immune to all three,
#      and it is the only form that actually grants a localhost origin CORS
#      on /token and /userinfo. The cost is that each dev port is listed
#      deliberately (5175 Flutter, 5174 admin Vite) — which is the point: the
#      list is reviewable by reading it. The same two ports, in the same
#      strict form, are the allow-list of
#      scripts/check-authorization-redirect-posture.sh, which validates EVERY
#      redirect URI on these providers, logout-typed ones included.
#
#      The URL is only half of an entry — `matching_mode` is asserted too, and
#      the "bare-origin regex" above is exactly why. Under `fullmatch` a
#      RENDERED origin read as a pattern turns every unescaped `.` into a
#      wildcard: staging's `https://beekeepingit-rc.melargil.pt` would then also
#      match `https://beekeepingit-rcamelargil.pt`, a registrable domain someone
#      can buy. So EVERY logout entry must be `strict`: the two rendered
#      origins and the two localhost dev ports alike, none of them a `regex`.
#      Duplicate `url:`/`matching_mode:`/`redirect_uri_type:` keys inside one
#      entry are rejected for the same last-wins reason as (1), every key and
#      value is read with QUOTES TOLERATED on either side (`redirect_uri_type:
#      "logout"` is the same entry to PyYAML, but a bare `: logout` pattern
#      missed it entirely — so an `https://evil.example/.*` written that way was
#      never recognised as a logout target and no allow-list assertion reached
#      it), and the list is walked by INDENTATION rather than fixed columns,
#      because a blank line or a re-indented item used to end the walk and
#      silently drop every entry below it — counters above it kept the guard
#      green (review findings).
#
#   3. NO `[` OR `]` IN ANY REDIRECT URI on these providers — logout,
#      authorization, `matching_mode: regex`, all of them. This one is not a
#      posture nicety, it is an outage: authentik derives its CORS allow-list
#      from `redirect_uris` and `urlparse()`s EVERY entry
#      (`providers/oauth2/utils.py::cors_allow`), and the image's Python raises
#      `ValueError: Invalid IPv6 URL` on a netloc with data before a `[`
#      (`_check_bracketed_netloc`). One bracketed entry therefore 500s every
#      request that carries an `Origin` header — the discovery document
#      included — so every browser sign-in dies with "Failed to fetch" while
#      in-cluster health probes, which send no Origin, stay green. That is
#      exactly what `http://localhost:[0-9]+` did on this change's first CI run
#      (15 of 25 e2e tests down, ~30 minutes to find out). The fix is not a
#      bracket-free character class: it is a STRICT LITERAL per dev port,
#      which has no character class at all — see (2).
#
#   4. NO OWNED `designation: invalidation` FLOW. (1) is spelled as a binding
#      onto upstream's flow rather than a flow of our own precisely because
#      owning one re-arms the trap the blueprint's #599 pin block documents:
#      with `brand.flow_invalidation` unpinned, `ToDefaultFlow.get_flow` scans
#      invalidation flows ORDERED BY SLUG and a `beekeepingit-*` slug sorts
#      ahead of `default-invalidation-flow`, so authentik's own UI logout would
#      start running our flow. If a future change does own one, it must pin the
#      brand field in the same PR — this assertion is what forces that
#      conversation instead of letting it land silently.
#
# Deterministic and offline: asserts over the blueprint SOURCE, with no cluster
# and no YAML parser (the file carries custom `!KeyOf`/`!Find`/`!Env` tags a
# plain parser would reject). Same engine style as
# scripts/check-federation-source-posture.sh.
#
# Run by `task repo:logout-invalidation-posture` -> `task repo:lint` -> `task ci`.
# An optional argument overrides the blueprint path. Live counterpart: the
# logout e2e in client/e2e/tests/slice.spec.ts. Written up in
# docs/architecture/auth.md §8.18.
#
# Exit codes: 0 = posture intact, 1 = drift.
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
blueprint="${1:-${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml}"

# The blueprint ids this guard pins. The stage is OWNED (a `UserLogoutStage`
# declares nothing but a name, so owning it costs nothing and cannot race
# another blueprint file's apply); the flow is upstream's, reached through the
# #599 identifiers-only pin entry.
logout_stage_id="stage-provider-invalidation-logout"
inval_flow_pin_id="flow-default-provider-invalidation"
logout_binding_id="binding-provider-invalidation-logout"
# Providers that MUST carry a logout allow-list, and the rendered origin each
# one must accept back. The PWA provider carries the admin origin too: the admin
# app signs out through THIS application's end_session_endpoint (it is pointed at
# the beekeepingit issuer — #460), so `application_slug` resolves here.
pwa_provider_id="provider-beekeepingit"
admin_provider_id="provider-beekeepingit-admin"

if [ ! -f "${blueprint}" ]; then
  printf '✗ [logout-invalidation] blueprint not found: %s\n' "${blueprint}" >&2
  exit 1
fi

# The chart does NOT read the path above. It renders
# `files/{{ .Values.blueprintFile }}`
# (charts/authentik/templates/blueprint-configmap.yaml), and `.Files.Get`
# returns the EMPTY STRING for a path that is not in the chart while raising
# nothing. So repointing that value — a rename, a typo, a second blueprint —
# ships a ConfigMap with no provider, no application and no seed user, and OIDC
# discovery 404s, while `helm lint`, `helm template` and every posture guard in
# this directory stay green against a file nothing mounts. `blueprintFile` is
# not in values.schema.json either, so nothing rejects a bogus value.
#
# Asserted rather than derived: deriving would need a YAML parser in a guard
# that is deliberately parser-free, and it would make this guard FOLLOW a
# repoint and then fail with "these entries are missing" — which reads like a
# blueprint regression rather than "someone moved the file". Skipped when an
# explicit path is given: that is a test fixture (review finding, #237).
if [ "$#" -eq 0 ]; then
  chart_values="${repo_root}/infra/helm/beekeepingit/charts/authentik/values.yaml"
  blueprint_basename="$(basename "${blueprint}")"
  if ! grep -qE "^blueprintFile:[[:space:]]*[\"']?${blueprint_basename}[\"']?[[:space:]]*\$" \
    "${chart_values}"; then
    printf '✗ [logout-invalidation] %s no longer sets `blueprintFile: %s`, so this guard is\n' \
      "${chart_values}" "${blueprint_basename}" >&2
    printf '  asserting over a file the chart does not ship. `.Files.Get` returns "" for a path\n' >&2
    printf '  that is not in the chart and raises nothing, so a repointed value deploys an EMPTY\n' >&2
    printf '  blueprint with every check green. Repoint this guard in the same change, or\n' >&2
    printf '  restore the value.\n' >&2
    exit 1
  fi
fi

# Strip whole-line comments only. An inline `#` would be inside a quoted string
# or a block scalar here (the brand's `branding_custom_css` carries `#E8B979`),
# and none of the keys below ever carry a trailing comment.
awk -v LOGOUT_STAGE="${logout_stage_id}" -v INVAL_PIN="${inval_flow_pin_id}" \
    -v LOGOUT_BINDING="${logout_binding_id}" \
    -v PWA="${pwa_provider_id}" -v ADMIN="${admin_provider_id}" '
  # The only redirect targets a logout entry may name, each with the ONE
  # `matching_mode` that makes it mean what it reads as. Compared as literal
  # template text so the check stays offline and every overlay is covered at
  # once. Returns the required mode, or "" for a target that is not allowed.
  #
  # The mode is half the assertion, not decoration: authentik matches a `regex`
  # entry with `re.fullmatch`, so `https://beekeepingit-rc.melargil.pt` read as
  # a pattern also matches `https://beekeepingit-rcamelargil.pt` — a DIFFERENT
  # registrable domain an attacker can buy. A rendered origin is a literal URL
  # and must therefore be `strict`; only the localhost dev entry is a pattern,
  # and only because a port cannot be spelled literally (review finding).
  function required_mode(u) {
    if (u == "{{ .Values.global.appOrigin }}") return "strict"
    if (u == "{{ .Values.global.adminOrigin }}") return "strict"
    # The dev exception, and it is a LITERAL, not a pattern: one strict entry
    # per real dev port, enumerated here so the list is reviewable by reading
    # it. A localhost REGEX is not an option in any spelling — `.*`, `\d+` and
    # `[0-9]+` are each unsafe on their own axis (see the header) — so all
    # three fall through to "not a reviewed target". A new dev port is a
    # deliberate edit to these two lines, matching the same two entries in
    # scripts/check-authorization-redirect-posture.sh (#822).
    if (u == "http://localhost:5175") return "strict"
    if (u == "http://localhost:5174") return "strict"
    return ""
  }

  function fail(msg) { printf "✗ [logout-invalidation] %s\n", msg > "/dev/stderr"; bad = 1 }

  # A YAML key AS IT MAY ACTUALLY BE WRITTEN. Two things every read below has to
  # tolerate, because PyYAML does and a pattern that does not is a hole:
  #   * the key may be QUOTED (`"redirect_uri_type": logout`), and
  #   * the value may be QUOTED (`redirect_uri_type: "logout"`).
  # The second one was a live open redirect: `redirect_uri_type: "logout"` is
  # the same logout entry to authentik, but a bare `:[[:space:]]*logout` pattern
  # never matched it, so the entry was not recognised as a logout target at all
  # and NO allow-list assertion ever reached its URL. An
  # `https://evil.example/.*` entry written that way passed cleanly (review
  # finding). The left boundary stays mandatory so a longer key ending in this
  # one — `jwt_url:` reading as `url:` — still does not satisfy it.
  function keypat(field) {
    return "(^|[^A-Za-z0-9_-])[\"'"'"']?" field "[\"'"'"']?[[:space:]]*:"
  }

  # `key:`s scalar value, with surrounding quotes of either kind stripped.
  # Returns "" when the key is absent.
  function scalar(text, field,   v, q, p) {
    if (!match(text, keypat(field) "[[:space:]]*")) return ""
    v = substr(text, RSTART + RLENGTH)
    if (v ~ /^["'"'"']/) {
      q = substr(v, 1, 1)
      v = substr(v, 2)
      p = index(v, q)
      if (p > 0) v = substr(v, 1, p - 1)
      return v
    }
    sub(/[^A-Za-z0-9_-].*$/, "", v)
    return v
  }

  # How many times a chunk of YAML DECLARES a key. Presence is not enough on its
  # own: PyYAML (authentiks `BlueprintLoader`) takes LAST-WINS on a duplicate
  # mapping key and raises nothing, so a second `target:` / `url:` would satisfy
  # a presence test while shipping the value it hides (review finding — the
  # sibling check-federation-source-posture.sh:194 hardened the same class).
  # `&` as the replacement leaves the text untouched; only the count is used.
  function key_count(text, field,   tmp) {
    tmp = text
    return gsub(keypat(field), "&", tmp)
  }

  # `state:` and `conditions:` on an entry this guard asserts EXISTS. Both make
  # the entry read as present while it does nothing: `state: absent` makes the
  # apply DELETE it, and a falsy `conditions:` list makes the planner skip the
  # binding. The blueprint already uses `conditions:` elsewhere, so neither is
  # hypothetical (review finding).
  function assert_live(what,   ok) {
    ok = 1
    if (key_count(body, "state") > 0) {
      fail(what " `" entry_id "` carries a `state:` key. Every value of it breaks this posture " \
           "silently while the text stays in the file: `absent` DELETES the object on apply, and " \
           "`created`/`must_created` SKIP the update on an environment where it already exists — " \
           "so the object keeps whatever it had before #237. An entry the posture depends on must " \
           "be applied unconditionally.")
      ok = 0
    }
    if (key_count(body, "conditions") > 0) {
      fail(what " `" entry_id "` carries a `conditions:` key. A falsy condition list makes the " \
           "planner skip it, so the entry exists and never runs — same outcome as deleting it " \
           "(#237). Keep the invalidation path unconditional.")
      ok = 0
    }
    return ok
  }

  # ---- entry boundaries -----------------------------------------------------
  /^[[:space:]]*#/ { next }

  # Every `redirect_uris:` KEY in the file, reconciled in END against the number
  # of lists this parser actually WALKED. A list written in a shape the walker
  # does not recognise would otherwise be invisible rather than rejected — the
  # difference between "no bad entry found" and "no entry looked at" (ported
  # from check-authorization-redirect-posture.sh, review finding).
  /redirect_uris[[:space:]]*:/ { keys_in_file++ }

  # A top-level entry this parser does not recognise — a flow-map
  # `  - { model: ..., attrs: {...} }`, reordered keys (`  - id:` first), or
  # extra spaces after the dash — is folded into the PREVIOUS entry body and
  # carries a whole provider past every check below. Reproduced in review: an
  # extra oauth2provider appended at EOF with `  - id:` before `model:`,
  # carrying a `regex https://evil.example/.*` logout target, passed this guard
  # untouched. Blueprint entries must be block-style.
  /^  - / && !/^  - model:/ {
    fail("top-level entry written in a form this guard cannot parse: `" $0 "`. Blueprint " \
         "entries must be block-style `  - model: <model>` so every provider, stage and " \
         "binding is examined — anything else is folded into the previous entry and never " \
         "looked at.")
  }

  /^  - model:/ {
    flush()
    # Normalised, not raw: `- model: "authentik_flows.flow"` and a trailing
    # space are both valid YAML and identical to PyYAML, but they defeat an
    # anchored match. A quoted model was a full bypass of assertion (3) — and
    # prettier PRESERVES those quotes, so `format-check` did not launder it
    # either (review finding).
    entry_model = $0; sub(/^  - model:[[:space:]]*/, "", entry_model)
    gsub(/[[:space:]"]/, "", entry_model)
    gsub(sprintf("%c", 39), "", entry_model)   # a single quote, unwritable inline here
    entry_id = ""; in_uris = 0; item = ""; n_items = 0
    body = ""
    next
  }

  { body = body " " $0 }

  /^    id:[[:space:]]*/ {
    if (entry_id == "") { entry_id = $0; sub(/^    id:[[:space:]]*/, "", entry_id) }
  }

  # ---- the redirect_uris list of the current entry ---------------------------
  # Driven off the indentation of the `redirect_uris:` KEY rather than a fixed
  # column, and blank lines are skipped rather than ending the list. The old
  # fixed-column rules dropped every entry after the first blank line or after
  # any re-indentation — both of which YAML (and prettier) accept — so an
  # `https://evil.example` appended below one passed assertion (4) untouched
  # while the counters above it stayed satisfied (review finding; the sibling
  # check-federation-source-posture.sh:538 already skips blank lines).
  #
  # A SECOND `redirect_uris:` block starts the collection over, because that is
  # what PyYAML does — last key wins. Accumulating both would make this guard
  # assert over the UNION of two lists while authentik applies only the last,
  # so a second block that drops the app/admin logout entries would pass here
  # and 400 every real sign-out in production (review finding). The union is
  # also why `n_items`/`items` must be cleared here and not only in flush().
  # The duplicate itself is still failed, in the provider branch below.
  /^[[:space:]]*redirect_uris:[[:space:]]*$/ {
    in_uris = 1; lists_parsed++; uris_indent = match($0, /[^ ]/) - 1
    item = ""; n_items = 0; delete items
    next
  }
  in_uris && /^[[:space:]]*$/ { next }
  in_uris {
    line_indent = match($0, /[^ ]/) - 1
    if (line_indent > uris_indent || ($0 ~ /^[[:space:]]*- / && line_indent == uris_indent)) {
      if ($0 ~ /^[[:space:]]*- /) { push_item(); item = $0 } else { item = item " " $0 }
      next
    }
    push_item(); in_uris = 0
  }

  function push_item() {
    if (item != "") { items[++n_items] = item; item = "" }
  }

  # ---- per-entry assertions --------------------------------------------------
  function flush(   i, it, url, mode, want, is_logout, n_logout, saw_app, saw_admin) {
    if (entry_model == "") return
    push_item()

    # (1) the user_logout stage, and (2) its binding onto UPSTREAMS invalidation
    # flow — both reached by !KeyOf, never !Find (#599: !Find resolves to None
    # silently, and a binding with a null target is not a binding). COUNTED, not
    # flagged: `n_* == 1` at the END is what makes a second, contradicting
    # declaration of the same object a failure instead of a no-op.
    if (entry_model ~ /authentik_stages_user_logout\.userlogoutstage/ && entry_id == LOGOUT_STAGE) {
      n_stage++
      assert_live("logout stage")
    }
    if (entry_model ~ /authentik_flows\.flowstagebinding/ &&
        body ~ ("target[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" INVAL_PIN "([^A-Za-z0-9_-]|$)") &&
        body ~ ("stage[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" LOGOUT_STAGE "([^A-Za-z0-9_-]|$)")) {
      n_binding++
      assert_live("invalidation binding")
      # Duplicate `target:`/`stage:` — last-wins, silently. A second
      # `target: !KeyOf flow-source-enrollment` binds the logout stage onto the
      # ENROLLMENT flow while this guard still reads the first one.
      if (key_count(body, "target") != 1)
        fail("invalidation binding `" entry_id "` declares `target:` " key_count(body, "target") \
             " times. PyYAML takes LAST-WINS silently, so the target this guard read is not " \
             "necessarily the one authentik applies. Declare it exactly once.")
      if (key_count(body, "stage") != 1)
        fail("invalidation binding `" entry_id "` declares `stage:` " key_count(body, "stage") \
             " times — last-wins, so the stage that actually binds may not be `" LOGOUT_STAGE "`.")
    }

    # (2b) ANY binding onto the pinned invalidation flow, not just ours. The
    # count above matches target AND stage, so a SECOND binding onto the same
    # flow carrying a different stage is invisible to it — and a redirect stage
    # bound at `order: 0` runs BEFORE the logout stage and sends the browser
    # away, leaving the SSO cookie alive with every other signal green (review
    # finding). This flow is upstream shared infrastructure: exactly one
    # binding belongs on it, and a second one is a conversation, not a merge.
    if (entry_model ~ /authentik_flows\.flowstagebinding/ &&
        body ~ ("target[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" INVAL_PIN "([^A-Za-z0-9_-]|$)"))
      n_inval_binding++

    # (2c) a POLICY binding onto our stage binding is `conditions:` by another
    # name: authentik evaluates policies attached to a FlowStageBinding and
    # SKIPS the stage when they deny, so a denying policy ends the session half
    # of #237 exactly as `conditions: [false]` would — which this guard already
    # rejects (review finding).
    if (entry_model ~ /authentik_policies\.policybinding/ &&
        body ~ ("target[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" LOGOUT_BINDING "([^A-Za-z0-9_-]|$)"))
      fail("entry `" entry_id "` binds a POLICY onto `" LOGOUT_BINDING "`. authentik SKIPS a " \
           "stage whose bound policies deny, so this disables the logout stage exactly as " \
           "`conditions:` would — and the invalidation path must stay unconditional (#237).")

    # (3) nothing in this file may OWN an invalidation-designation flow.
    if (entry_model ~ /authentik_flows\.flow$/ &&
        body ~ (keypat("designation") "[[:space:]]*[\"'"'"']?invalidation([^A-Za-z0-9_-]|$)"))
      fail("entry `" entry_id "` OWNS a `designation: invalidation` flow. That re-arms the " \
           "slug-ordering trap the blueprints #599 pin block documents: pin " \
           "`brand.flow_invalidation` in the same change, then relax this assertion.")

    # (4) every logout-typed redirect URI, on every provider — and (5) the flow
    # the binding above is attached to is the one each provider invalidates
    # through.
    if (entry_model ~ /authentik_providers_oauth2\.oauth2provider/) {
      # The providers CARRY the whole allow-list, so they need the same
      # is-this-entry-actually-applied check as the stage and the binding. On
      # an environment where the provider already exists, `state: created` (or
      # `must_created`), or a falsy `conditions:`, means the blueprints
      # `redirect_uris` is never written to it: the provider silently keeps its
      # pre-#237 list, `post_logout_redirect_uris` stays empty, and Sign out
      # dead-ends on the interstitial again — with Flux green, the blueprint
      # `status: successful`, and this guard green (review finding).
      assert_live("provider")

      # Exactly ONE `redirect_uris:` block. PyYAML is last-wins, so a second
      # block silently replaces the list this guard just walked; the shape that
      # matters keeps every authorization entry (so sign-IN and the e2e stay
      # green) while dropping the app/admin logout entries, which leaves
      # validation strict and 400s every real sign-out. prettier accepts
      # duplicate YAML keys without a warning, and nothing else reads this file
      # offline (review finding).
      if (key_count(body, "redirect_uris") != 1)
        fail("provider `" entry_id "` declares `redirect_uris:` " key_count(body, "redirect_uris") \
             " times. PyYAML takes LAST-WINS silently, so the list authentik applies is not the " \
             "one reviewed here — and a second block that drops the logout entries turns every " \
             "sign-out into a 400. Declare it exactly once.")

      # (5) Without this, repointing BOTH providers at another flow leaves the
      # binding correct, attached, and unreachable — the stage never runs and
      # #237s session half returns with the guard still green.
      if (key_count(body, "invalidation_flow") != 1 ||
          body !~ ("invalidation_flow[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" INVAL_PIN "([^A-Za-z0-9_-]|$)"))
        fail("provider `" entry_id "` must set `invalidation_flow: !KeyOf " INVAL_PIN "` exactly " \
             "once. The logout stage is bound onto THAT flow — point the provider anywhere else " \
             "and the binding is still there, still correct, and never planned (#237).")

      n_logout = 0; saw_app = 0; saw_admin = 0
      for (i = 1; i <= n_items; i++) {
        it = items[i]

        # (6) NO SQUARE BRACKET IN ANY redirect URI on this provider — logout,
        # authorization, regex-mode, all of them. authentik derives its CORS
        # allow-list from `redirect_uris` and `urlparse()`s every entry
        # (`providers/oauth2/utils.py::cors_allow`); the images Python rejects a
        # netloc with data before a `[` (`_check_bracketed_netloc` ->
        # `ValueError: Invalid IPv6 URL`), so ONE bracketed entry 500s every
        # browser request that carries an `Origin` header — the discovery
        # document included. In-cluster probes send no Origin and stay green, so
        # the only symptom is every browser sign-in failing with "Failed to
        # fetch". `http://localhost:[0-9]+` did exactly that on this PRs first
        # CI run (15/25 e2e tests down); `\\d+` is the same class, bracket-free.
        if (index(it, "[") > 0 || index(it, "]") > 0)
          fail("provider `" entry_id "` has a redirect URI containing `[` or `]`: " it \
               ". authentik `urlparse()`s EVERY redirect_uris entry to build its CORS allow-list, " \
               "and a netloc with data before a `[` raises `Invalid IPv6 URL` — which 500s the " \
               "discovery document for any request with an `Origin` header and breaks every " \
               "browser sign-in, while in-cluster health probes stay green. Use `\\d`, not `[0-9]`.")

        # `redirect_uri_type` is what decides whether this entry is inspected at
        # all, so its duplicate check runs on EVERY entry and BEFORE that
        # decision. Otherwise `redirect_uri_type: authorization` followed by
        # `redirect_uri_type: logout` reads as authorization here, is skipped,
        # and ships as a logout target under PyYAMLs last-wins.
        if (key_count(it, "redirect_uri_type") > 1) {
          fail("provider `" entry_id "` has a redirect entry declaring `redirect_uri_type:` more " \
               "than once. PyYAML takes last-wins silently, so the type this guard read is not " \
               "the type authentik applies: " it)
          continue
        }

        is_logout = (scalar(it, "redirect_uri_type") == "logout")
        if (!is_logout) continue
        n_logout++
        # One `url:` and one `matching_mode:` per entry — a duplicate is
        # last-wins in PyYAML, so a second `url:` would ship a target this guard
        # never reads.
        if (key_count(it, "url") != 1 || key_count(it, "matching_mode") != 1) {
          fail("provider `" entry_id "` has a logout redirect entry that declares `url:` or " \
               "`matching_mode:` more than once (or not at all). " \
               "PyYAML takes last-wins silently: " it)
          continue
        }
        # The value must be QUOTED — this guard and every reviewer read it, and
        # a bare `{{ ... }}` is not even valid YAML. The KEY may be quoted too.
        if (!match(it, keypat("url") "[[:space:]]*[\"'"'"']")) {
          fail("provider `" entry_id "` has a logout redirect URI with no QUOTED `url:` — " \
               "this guard (and review) reads that value; quote it.")
          continue
        }
        url = scalar(it, "url")

        want = required_mode(url)
        if (want == "") {
          fail("provider `" entry_id "` allow-lists logout redirect `" url "`, which is none of " \
               "the four reviewed targets: `{{ .Values.global.appOrigin }}`, " \
               "`{{ .Values.global.adminOrigin }}`, `http://localhost:5175` and " \
               "`http://localhost:5174` — every one of them a STRICT literal. A logout " \
               "allow-list entry IS the open-redirect boundary, so each target is either " \
               "rendered from this charts values or one enumerated dev port. A localhost REGEX " \
               "is not an option in any spelling: `.*` admits `http://localhost:@evil.example`, " \
               "`\\d` admits unicode digits and raises in `cors_allow`, and `[0-9]` is a " \
               "bracketed netloc that 500s every request carrying an `Origin` header. A new dev " \
               "port is a deliberate edit to this guard and to the authorization one (#822).")
          continue
        }

        mode = scalar(it, "matching_mode")
        if (mode != want)
          fail("provider `" entry_id "` allow-lists logout redirect `" url "` with " \
               "`matching_mode: " mode "`, but it must be `" want "`. authentik matches a regex " \
               "entry with `re.fullmatch`, so a rendered origin read as a pattern turns every " \
               "unescaped `.` into a wildcard and admits a DIFFERENT registrable domain — the " \
               "open redirect this list exists to prevent.")

        if (url == "{{ .Values.global.appOrigin }}") saw_app = 1
        if (url == "{{ .Values.global.adminOrigin }}") saw_admin = 1
      }
      if (n_logout == 0)
        fail("provider `" entry_id "` declares NO `redirect_uri_type: logout` entry, so " \
             "`EndSessionView.validate` silently ignores the clients `post_logout_redirect_uri` " \
             "and Sign out dead-ends on the session-end interstitial again (#237).")
      if (entry_id == PWA && !saw_app)
        fail("provider `" entry_id "` must allow-list `{{ .Values.global.appOrigin }}` for logout " \
             "— that is where the PWA sends `post_logout_redirect_uri`.")
      if (entry_id == PWA && !saw_admin)
        fail("provider `" entry_id "` must allow-list `{{ .Values.global.adminOrigin }}` for " \
             "logout: the admin app signs out through THIS applications end_session_endpoint " \
             "(#460), so without it admin sign-out 400s.")
      if (entry_id == ADMIN && !saw_admin)
        fail("provider `" entry_id "` must allow-list `{{ .Values.global.adminOrigin }}` for logout.")
      seen_pwa = seen_pwa || (entry_id == PWA)
      seen_admin_provider = seen_admin_provider || (entry_id == ADMIN)
    }

    entry_model = ""; n_items = 0; delete items
  }

  END {
    flush()
    if (n_stage != 1)
      fail("expected EXACTLY ONE `authentik_stages_user_logout.userlogoutstage` entry with id `" \
           LOGOUT_STAGE "`, found " (n_stage+0) ". Without it the authentik SSO session outlives " \
           "Sign out and re-entry needs no password (#237, NFR-SEC-1); with two, the last one " \
           "wins and this guard read the wrong one.")
    if (n_binding != 1)
      fail("expected EXACTLY ONE `authentik_flows.flowstagebinding` binding `" LOGOUT_STAGE \
           "` onto `" INVAL_PIN "` by !KeyOf, found " (n_binding+0) ". An unbound logout stage ends " \
           "nothing, and a second binding entry decides what the first one meant.")
    if (n_inval_binding != 1)
      fail("expected EXACTLY ONE `flowstagebinding` onto `" INVAL_PIN "`, found " \
           (n_inval_binding+0) ". That flow is upstream shared infrastructure: a SECOND " \
           "binding on it — any stage, any order — runs alongside the logout stage, and one " \
           "at a lower `order` runs BEFORE it and can send the browser away with the SSO " \
           "session intact.")
    if (keys_in_file != lists_parsed)
      fail("found " (keys_in_file+0) " `redirect_uris:` key(s) in the file but walked " \
           (lists_parsed+0) ". A list this parser cannot see is not a list it approved — the " \
           "difference between no bad entry found and no entry looked at. Write every " \
           "`redirect_uris:` as a block-style key with its items indented under it.")
    if (!seen_pwa)   fail("provider entry `" PWA "` not found — this guard has drifted from the blueprint.")
    if (!seen_admin_provider) fail("provider entry `" ADMIN "` not found — this guard has drifted from the blueprint.")
    if (bad) exit 1
    printf "✓ [logout-invalidation] provider invalidation flow ends the session; logout redirects allow-list only rendered origins\n"
  }
' "${blueprint}"
