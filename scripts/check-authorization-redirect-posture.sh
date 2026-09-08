#!/usr/bin/env bash
# Guard: no OAuth2 provider in the Authentik blueprint may allow-list a redirect
# URI that is not a numeric-port localhost dev origin or an origin this chart
# itself renders (#822, NFR-SEC-1, D-7).
#
# WHAT THIS PREVENTS, concretely — the entry this guard was written for shipped
# `{ matching_mode: regex, url: "http://localhost:.*" }` on BOTH providers, in
# EVERY environment, and that is a complete account-takeover chain, verified
# against the pinned authentik 2026.5.4 source:
#
#   1. An authorization redirect URI is matched with `re.fullmatch`
#      (`providers/oauth2/views/authorize.py::check_redirect_uri`), and
#      `fullmatch("http://localhost:.*", "http://localhost:@evil.example")`
#      PASSES — everything after `localhost:` is unconstrained. A browser
#      resolves that URL to host `evil.example` with `localhost:` as USERINFO,
#      so the `?code=` (and `state`) land on an attacker origin.
#   2. PKCE is not mandatory: `check_code_challenge` validates only the METHOD,
#      so an attacker crafting the authorize URL simply omits `code_challenge`.
#   3. `/token` requires a client secret only for `ClientType.CONFIDENTIAL`
#      (`views/token.py`), and both our providers are `client_type: public`.
#
#   Net: a victim with a live SSO cookie clicking one crafted link hands over an
#   access token AND a 30-day refresh token. Nothing about that needs the
#   attacker to control the victim's machine, and nothing in review reliably
#   catches one `.*` in a URL that "obviously" only means localhost.
#
#   The same entry also 500s CORS: `cors_allow` (`providers/oauth2/utils.py`)
#   compares `scheme`, then `hostname`, then `urlparse(entry).port` — and
#   `urlparse("http://localhost:.*").port` raises ValueError. Scheme and
#   hostname match first for any `Origin: http://localhost:<anything>`, so a
#   localhost dev origin turned a /token or /userinfo response into a 500.
#
# WHY THE APPROVED FORMS ARE SAFE (each verified with Python's `re.fullmatch`
# against the attack set, #822):
#   * `http://localhost:[0-9]+(/.*)?` — a DIGIT is required immediately after
#     `:`, so no userinfo is expressible (`@` needs a non-digit there); `[0-9]`
#     rather than `\d` closes the unicode-digit hole (`http://localhost:٤٥`
#     fails); and the path wildcard is safe because an `@` after the first `/`
#     is path, never userinfo. The group is optional so the BARE ORIGIN still
#     matches, which is what the CORS derivation reads.
#   * `http://localhost:[0-9]+` — the same origin without a path (#237's
#     logout-typed form; a `post_logout_redirect_uri` carries no path).
#   * A `{{ .Values.global.appOrigin }}` / `{{ .Values.global.adminOrigin }}`
#     template, optionally `/.*`-suffixed — the per-environment origins this
#     chart renders, so every overlay allow-lists exactly its own hosts and
#     nothing hand-written can drift in.
#
# EVERY redirect URI is checked, of EVERY `redirect_uri_type`, deliberately:
# `views/token.py` builds the CORS allow-list as `[x.url for x in
# provider.redirect_uris]` — ALL types, UNFILTERED — so a logout-typed entry
# naming a new origin silently widens CORS on /token and /userinfo even though
# it widens no authorization target. (The logout-specific posture — that the
# list is non-empty and covers the right origins — is asserted separately by
# scripts/check-logout-invalidation-posture.sh, #237.)
#
# Deterministic and offline: asserts over the blueprint SOURCE, with no cluster
# and no YAML parser (the file carries custom `!KeyOf`/`!Find`/`!Env` tags a
# plain parser would reject). Same engine style as
# scripts/check-federation-source-posture.sh.
#
# Run by `task repo:authorization-redirect-posture` -> `task repo:lint` ->
# `task ci`. An optional argument overrides the blueprint path.
#
# Exit codes: 0 = posture intact, 1 = drift.
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
blueprint="${1:-${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml}"

# Both providers must still be here: a guard that silently stops finding its
# subject asserts nothing.
pwa_provider_id="provider-beekeepingit"
admin_provider_id="provider-beekeepingit-admin"

if [ ! -f "${blueprint}" ]; then
  printf '✗ [authorization-redirect] blueprint not found: %s\n' "${blueprint}" >&2
  exit 1
fi

awk -v PWA="${pwa_provider_id}" -v ADMIN="${admin_provider_id}" '
  function fail(msg) { printf "✗ [authorization-redirect] %s\n", msg > "/dev/stderr"; bad = 1 }

  # Pull the QUOTED value of `url:` out of one (possibly multi-line, already
  # space-joined) list item. Both quote styles are in use: the localhost entries
  # are double-quoted, the Helm-template regexes single-quoted (their body
  # contains double quotes). An unquoted value fails closed below.
  function extract_url(it,   q, rest) {
    if (!match(it, /url[[:space:]]*:[[:space:]]*["'"'"']/)) return "\001"
    q = substr(it, RSTART + RLENGTH - 1, 1)
    rest = substr(it, RSTART + RLENGTH)
    if (index(rest, q) == 0) return "\001"
    return substr(rest, 1, index(rest, q) - 1)
  }

  # A literal (non-template) URL may only be one of the two tightened localhost
  # dev forms. Exact strings, not a pattern: this is an allow-list, and any new
  # shape must be added here deliberately rather than slipped past by a regex
  # that "looks about right".
  function allowed_literal(u) {
    return (u == "http://localhost:[0-9]+(/.*)?" || u == "http://localhost:[0-9]+")
  }

  # A template URL must be built ENTIRELY from origins this chart renders:
  # nothing before the `{{`, only `.Values.global.appOrigin` /
  # `.Values.global.adminOrigin` inside, at most a `/.*` path suffix after the
  # last `}}`, and no wildcard smuggled into the pipeline (the legitimate
  # `replace "." "\\."` filter contains none).
  function allowed_template(u, why,   head, tail, inner, rest, path, n) {
    head = u; sub(/{{.*$/, "", head)
    if (head != "") { why[0] = "text before the `{{` template (`" head "`) — the origin must come entirely from values this chart renders"; return 0 }
    tail = u; sub(/^.*}}/, "", tail)
    if (tail != "" && tail != "/.*") { why[0] = "the suffix `" tail "` after the template; only an empty suffix (bare origin) or `/.*` (path) is allowed"; return 0 }
    inner = u; sub(/^[^{]*{{/, "", inner); sub(/}}[^}]*$/, "", inner)
    if (inner ~ /\.\*|\.\+|\.\{|\\d|\[\^/) { why[0] = "a regex wildcard inside the template body (`" inner "`)"; return 0 }
    n = 0; rest = u
    while (match(rest, /\.Values\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*/)) {
      path = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      n++
      if (path != ".Values.global.appOrigin" && path != ".Values.global.adminOrigin") {
        why[0] = "the value `" path "`; only `.Values.global.appOrigin` and `.Values.global.adminOrigin` name an origin this chart renders"
        return 0
      }
    }
    if (n < 1) { why[0] = "a template that references no `.Values.global.*Origin` at all"; return 0 }
    return 1
  }

  # ---- entry boundaries -----------------------------------------------------
  # Whole-line comments only: an inline `#` here would be inside a quoted string
  # or a block scalar. Skipping them FIRST also keeps a comment between two list
  # items from being read as the end of the list.
  /^[[:space:]]*#/ { next }

  /^  - model:/ {
    flush()
    entry_model = $0; sub(/^  - model:[[:space:]]*/, "", entry_model)
    entry_id = ""; in_uris = 0; item = ""; n_items = 0
    next
  }

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

  # ---- per-provider assertions ----------------------------------------------
  function flush(   i, it, url, why, n_authz) {
    if (entry_model == "") return
    push_item()
    if (entry_model !~ /authentik_providers_oauth2\.oauth2provider/) { entry_model = ""; n_items = 0; delete items; return }

    seen[entry_id] = 1
    n_authz = 0
    for (i = 1; i <= n_items; i++) {
      it = items[i]
      # `redirect_uri_type` defaults to AUTHORIZATION (providers/oauth2/models.py),
      # so an entry that does not say `logout` IS an authorization target.
      if (it !~ /redirect_uri_type[[:space:]]*:[[:space:]]*logout([^A-Za-z0-9_-]|$)/) n_authz++
      url = extract_url(it)
      if (url == "\001") {
        fail("provider `" entry_id "` has a redirect URI with no QUOTED `url:` value — this guard (and review) reads that value; quote it.")
        continue
      }
      if (url == "http://localhost:.*") {
        fail("provider `" entry_id "` allow-lists `http://localhost:.*`. That fullmatches " \
             "`http://localhost:@evil.example`, which a browser resolves to evil.example with " \
             "`localhost:` as userinfo — the authorization code leaks to an attacker origin and " \
             "is redeemable with no secret and no PKCE verifier (#822). It also makes " \
             "`urlparse(...).port` raise inside `cors_allow`, 500ing a localhost Origin. Use " \
             "`http://localhost:[0-9]+(/.*)?`.")
        continue
      }
      if (url ~ /{{/) {
        if (!allowed_template(url, why))
          fail("provider `" entry_id "` allow-lists redirect `" url "` — rejected for " why[0] ".")
        continue
      }
      if (!allowed_literal(url))
        fail("provider `" entry_id "` allow-lists redirect `" url "`, which is neither a " \
             "`{{ .Values.global.appOrigin }}`/`{{ .Values.global.adminOrigin }}` template nor " \
             "one of the tightened localhost dev forms `http://localhost:[0-9]+(/.*)?` / " \
             "`http://localhost:[0-9]+`. Every redirect URI is an authorization target OR a CORS " \
             "origin on /token and /userinfo (`token.py` builds that list from ALL redirect_uris, " \
             "unfiltered) — keep every target an origin this chart itself renders (#822, NFR-SEC-1).")
    }
    if (n_authz == 0)
      fail("provider `" entry_id "` declares no authorization redirect URI at all — every login " \
           "through it would fail `check_redirect_uri`.")

    entry_model = ""; n_items = 0; delete items
  }

  END {
    flush()
    if (!(PWA in seen))   fail("provider entry `" PWA "` not found — this guard has drifted from the blueprint.")
    if (!(ADMIN in seen)) fail("provider entry `" ADMIN "` not found — this guard has drifted from the blueprint.")
    if (bad) exit 1
    printf "✓ [authorization-redirect] every provider redirect URI is a rendered origin or a numeric-port localhost dev origin\n"
  }
' "${blueprint}"
