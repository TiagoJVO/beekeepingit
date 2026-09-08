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
#      stage exists": an unbound stage is decoration.
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
#      — or the ONE tightened localhost dev regex. A literal host, a `.*`, or a
#      bare-origin regex would turn a validated allow-list back into an open
#      redirect while still looking like a list. `http://localhost:.*` is
#      rejected by name: matching is `fullmatch`, and that pattern also accepts
#      `http://localhost:@evil.example`, which a browser resolves to
#      evil.example.
#
#   3. NO OWNED `designation: invalidation` FLOW. (1) is spelled as a binding
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

# Strip whole-line comments only. An inline `#` would be inside a quoted string
# or a block scalar here (the brand's `branding_custom_css` carries `#E8B979`),
# and none of the keys below ever carry a trailing comment.
awk -v LOGOUT_STAGE="${logout_stage_id}" -v INVAL_PIN="${inval_flow_pin_id}" \
    -v PWA="${pwa_provider_id}" -v ADMIN="${admin_provider_id}" '
  # The only two redirect targets a logout entry may name: the per-environment
  # origins this chart renders. Compared as literal template text so the check
  # stays offline and every overlay is covered at once.
  function allowed_logout_url(u) {
    if (u == "{{ .Values.global.appOrigin }}") return 1
    if (u == "{{ .Values.global.adminOrigin }}") return 1
    # The one dev exception: a localhost ORIGIN with a numeric port. `[0-9]+`
    # and nothing looser — see the header.
    if (u == "http://localhost:[0-9]+") return 1
    return 0
  }

  function fail(msg) { printf "✗ [logout-invalidation] %s\n", msg > "/dev/stderr"; bad = 1 }

  # ---- entry boundaries -----------------------------------------------------
  /^[[:space:]]*#/ { next }

  /^  - model:/ {
    flush()
    entry_model = $0; sub(/^  - model:[[:space:]]*/, "", entry_model)
    entry_id = ""; in_uris = 0; item = ""; n_items = 0
    body = ""
    next
  }

  { body = body " " $0 }

  /^    id:[[:space:]]*/ {
    if (entry_id == "") { entry_id = $0; sub(/^    id:[[:space:]]*/, "", entry_id) }
  }

  # ---- the redirect_uris list of the current entry ---------------------------
  /^      redirect_uris:[[:space:]]*$/ { in_uris = 1; next }
  in_uris && /^        - / { push_item(); item = $0; next }
  in_uris && /^          / { item = item " " $0; next }
  in_uris { push_item(); in_uris = 0 }

  function push_item() {
    if (item != "") { items[++n_items] = item; item = "" }
  }

  # ---- per-entry assertions --------------------------------------------------
  function flush(   i, it, url, is_logout, n_logout, saw_app, saw_admin) {
    if (entry_model == "") return
    push_item()

    # (1) the user_logout stage, and (2) its binding onto UPSTREAMS invalidation
    # flow — both reached by !KeyOf, never !Find (#599: !Find resolves to None
    # silently, and a binding with a null target is not a binding).
    if (entry_model ~ /authentik_stages_user_logout\.userlogoutstage/ && entry_id == LOGOUT_STAGE)
      seen_stage = 1
    if (entry_model ~ /authentik_flows\.flowstagebinding/ &&
        body ~ ("target[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" INVAL_PIN "([^A-Za-z0-9_-]|$)") &&
        body ~ ("stage[[:space:]]*:[[:space:]]*!KeyOf[[:space:]]+" LOGOUT_STAGE "([^A-Za-z0-9_-]|$)"))
      seen_binding = 1

    # (3) nothing in this file may OWN an invalidation-designation flow.
    if (entry_model ~ /authentik_flows\.flow$/ &&
        body ~ /designation[[:space:]]*:[[:space:]]*invalidation([^A-Za-z0-9_-]|$)/)
      fail("entry `" entry_id "` OWNS a `designation: invalidation` flow. That re-arms the " \
           "slug-ordering trap the blueprints #599 pin block documents: pin " \
           "`brand.flow_invalidation` in the same change, then relax this assertion.")

    # (4) every logout-typed redirect URI, on every provider.
    if (entry_model ~ /authentik_providers_oauth2\.oauth2provider/) {
      n_logout = 0; saw_app = 0; saw_admin = 0
      for (i = 1; i <= n_items; i++) {
        it = items[i]
        is_logout = (it ~ /redirect_uri_type[[:space:]]*:[[:space:]]*logout([^A-Za-z0-9_-]|$)/)
        if (!is_logout) continue
        n_logout++
        url = it
        if (!match(url, /url[[:space:]]*:[[:space:]]*["'"'"']/)) {
          fail("provider `" entry_id "` has a logout redirect URI with no QUOTED `url:` — " \
               "this guard (and review) reads that value; quote it.")
          continue
        }
        url = substr(url, RSTART + RLENGTH)
        sub(/["'"'"'].*$/, "", url)
        if (!allowed_logout_url(url))
          fail("provider `" entry_id "` allow-lists logout redirect `" url "`, which is neither " \
               "`{{ .Values.global.appOrigin }}`/`{{ .Values.global.adminOrigin }}` nor the " \
               "tightened `http://localhost:[0-9]+` dev regex. A logout allow-list entry IS the " \
               "open-redirect boundary — keep every target rendered from this charts values.")
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
    if (!seen_stage)
      fail("no `authentik_stages_user_logout.userlogoutstage` entry with id `" LOGOUT_STAGE "`. " \
           "Without it the authentik SSO session outlives Sign out and re-entry needs no " \
           "password (#237, NFR-SEC-1).")
    if (!seen_binding)
      fail("no `authentik_flows.flowstagebinding` binding `" LOGOUT_STAGE "` onto `" INVAL_PIN \
           "` by !KeyOf. An unbound logout stage ends nothing.")
    if (!seen_pwa)   fail("provider entry `" PWA "` not found — this guard has drifted from the blueprint.")
    if (!seen_admin_provider) fail("provider entry `" ADMIN "` not found — this guard has drifted from the blueprint.")
    if (bad) exit 1
    printf "✓ [logout-invalidation] provider invalidation flow ends the session; logout redirects allow-list only rendered origins\n"
  }
' "${blueprint}"
