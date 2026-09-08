#!/usr/bin/env bash
# Guard: every redirect URI on every OAuth2 provider in the Authentik blueprint
# must be one of a small set of EXACT, reviewed forms — a STRICT localhost dev
# origin naming one real dev port, or an origin this chart itself renders
# (#822, NFR-SEC-1, D-7).
#
# WHAT THIS PREVENTS, concretely — the entry this guard was written for shipped
# `{ matching_mode: regex, url: "http://localhost:.*" }` on BOTH providers, in
# EVERY environment, and that is a complete account-takeover chain, verified
# against the pinned authentik 2026.5.4 source:
#
#   1. An authorization redirect URI is matched with `re.fullmatch`
#      (`providers/oauth2/views/authorize.py::check_redirect_uri`, which
#      normalizes nothing), and
#      `fullmatch("http://localhost:.*", "http://localhost:@evil.example")`
#      PASSES — everything after `localhost:` is unconstrained. A browser
#      resolves that URL to host `evil.example` with `localhost:` as USERINFO,
#      so the `?code=` (and `state`) land on an attacker origin.
#   2. PKCE is not mandatory: `check_code_challenge` validates only the METHOD
#      (`if self.code_challenge and self.code_challenge_method not in [...]`),
#      so an attacker crafting the authorize URL simply omits `code_challenge`.
#   3. `/token` requires a client secret only for `ClientType.CONFIDENTIAL`
#      (`views/token.py`), and both our providers are `client_type: public`.
#
#   Net: a victim with a live SSO cookie clicking one crafted link hands over an
#   access token AND a 30-day refresh token. Nothing about that needs the
#   attacker to control the victim's machine, and nothing in review reliably
#   catches one `.*` in a URL that "obviously" only means localhost.
#
#   The same entry also broke CORS loudly: `cors_allow`
#   (`providers/oauth2/utils.py`) compares `scheme`, then `hostname`, then
#   `urlparse(entry).port` — and `urlparse("http://localhost:.*").port` raises
#   ValueError, while scheme and hostname match first for any
#   `Origin: http://localhost:<anything>`. So a localhost dev origin turned a
#   /token or /userinfo response into a 500.
#
# WHY THE LOCALHOST ENTRIES ARE STRICT AND NOT A REGEX (owner decision on #822,
# 2026-09-08). Two narrower regexes were proposed to replace `.*`, and each is
# unsafe on its own axis — both verified by RUNNING Python 3.11.0's `re` and
# `urlparse`, not by reading the pattern:
#   * `http://localhost:\d+(/.*)?` — `\d` matches UNICODE decimal digits:
#     `re.fullmatch(r"http://localhost:\d+(/.*)?", "http://localhost:٤٥")`
#     PASSES (Arabic-Indic 45), so a URL resolving to nothing like a port is
#     allow-listed; `[0-9]` rejects it. It ALSO reproduces the CORS 500 above:
#     `urlparse(r"http://localhost:\d+(/.*)?")` gives hostname `localhost`
#     (which matches a localhost `Origin`) and then raises on `.port`
#     — `ValueError: Port could not be cast to integer value as '\d+('`.
#   * `http://localhost:[0-9]+(/.*)?` — a BRACKETED host. On Python 3.11.0
#     `urlparse` reads the hostname as `0-9` and `.port` is None (harmless, but
#     it grants no localhost CORS either); later CPython validates bracketed
#     netlocs harder and the authentik image reportedly raises
#     `ValueError: Invalid IPv6 URL`, which 500s the discovery document for any
#     request carrying an `Origin` header. That cost PR #823 a 30-minute k3d
#     run before it was traced.
# So `[`, `]` and `\d` are BANNED outright in any redirect URI below, and the
# localhost entries are strict literals. A strict literal has no regex
# metacharacter at all: it parses identically on every Python version, has no
# unicode-digit surface, cannot widen the CORS origins `token.py` derives from
# `redirect_uris`, and `urlparse` returns a real hostname + port (which is what
# actually grants a localhost dev origin CORS on /token and /userinfo).
#
# WHY THE APPROVED FORMS ARE SAFE (#822):
#   * `http://localhost:5175` (strict) — the Flutter client's dev server.
#     `flutter run -d chrome` binds a RANDOM ephemeral port unless told
#     otherwise, so `client/README.md` pins `--web-port 5175`; a strict entry
#     cannot cover a random port, and that is the trade the decision accepts.
#   * `http://localhost:5174` (strict) — the admin app's Vite dev server,
#     pinned by `admin/vite.config.ts` (`server.port: 5174`). Present on BOTH
#     providers: on the admin provider as its own redirect target, and on the
#     pwa provider because the admin app reads the beekeepingit application's
#     discovery + JWKS cross-origin (#460).
#     Both forms are also the ones the logout-typed entries landing with
#     #237/#823 must use — a strict entry carries no path either way, so that
#     change composes with this one with no new allow-list form.
#   * ADDING A PORT IS A DELIBERATE EDIT HERE. That is the cost of dropping the
#     regex, and the benefit: the dev origins authentik trusts are readable as
#     a list rather than inferred from a pattern.
#   * The `{{ .Values.global.appOrigin }}` / `{{ .Values.global.adminOrigin }}`
#     templates, in EXACTLY two spellings: strict and bare (the redirect the
#     apps actually send, and the origin the CORS derivation reads), or regex
#     WITH the `| replace "." "\\." }}` dot-escape and a `/.*` path. The escape
#     is load-bearing and is why this guard matches whole strings rather than
#     "a template mentioning appOrigin": dropping it leaves the regex
#     `https://app.beekeepingit.com/.*`, whose unescaped dots fullmatch a
#     registrable look-alike like `https://app-beekeepingit.com/cb`.
#
# EVERY redirect URI is checked, of EVERY `redirect_uri_type`, deliberately:
# `views/token.py` builds the CORS allow-list as `[x.url for x in
# provider.redirect_uris]` — ALL types, UNFILTERED — so a logout-typed entry
# naming a new origin silently widens CORS on /token and /userinfo even though
# it widens no authorization target.
#
# FAIL-CLOSED IS THE POINT. This is a textual assertion over a file that carries
# custom `!KeyOf`/`!Find`/`!Env` tags (no YAML parser will load it) and is
# rendered through Helm `tpl`. Anything it cannot read with certainty — an
# unquoted or duplicated `url:`, a list item at an unexpected indentation, a
# Helm action inside the list, a provider written as a flow map, a
# `redirect_uris:` key it never parsed — is an ERROR, not a pass. A guard that
# quietly stops looking is worse than no guard.
#
# Deterministic and offline: no cluster. Same engine style as
# scripts/check-federation-source-posture.sh. Exercised by
# scripts/test-authorization-redirect-posture.sh, which runs the tampering this
# guard exists to catch and asserts each one fails.
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

# The allow-list, as `<matching_mode> <url>` pairs. Exported rather than passed
# with `awk -v`, because -v interprets backslash escapes and the two regex
# templates carry a literal `\\.` dot-escape that must survive verbatim.
export BKI_ALLOWED_REDIRECTS='strict http://localhost:5175
strict http://localhost:5174
regex {{ .Values.global.appOrigin | replace "." "\\." }}/.*
regex {{ .Values.global.adminOrigin | replace "." "\\." }}/.*
strict {{ .Values.global.appOrigin }}
strict {{ .Values.global.adminOrigin }}'

awk -v PWA="${pwa_provider_id}" -v ADMIN="${admin_provider_id}" '
  function fail(msg) { printf "✗ [authorization-redirect] %s\n", msg > "/dev/stderr"; bad = 1 }

  BEGIN {
    n_allowed = split(ENVIRON["BKI_ALLOWED_REDIRECTS"], allowed_lines, "\n")
    for (i = 1; i <= n_allowed; i++) allowed[allowed_lines[i]] = 1
  }

  # How many `url:` KEYS one item carries. PyYAML (what authentik loads the
  # blueprint with) keeps the LAST of a duplicated key while this guard would
  # read the first, so a second `url:` is a place to hide one.
  function count_url_keys(it,   probe) {
    probe = it
    return gsub(/(^|[[:space:],{])url[[:space:]]*:/, "", probe)
  }

  # Pull the QUOTED value of `url:` out of one (possibly multi-line, already
  # space-joined) list item. Both quote styles are in use: the localhost entries
  # are double-quoted, the Helm-template regexes single-quoted (their body
  # contains double quotes). An unquoted value returns the sentinel.
  function extract_url(it,   q, rest) {
    if (!match(it, /url[[:space:]]*:[[:space:]]*["'"'"']/)) return "\001"
    q = substr(it, RSTART + RLENGTH - 1, 1)
    rest = substr(it, RSTART + RLENGTH)
    if (index(rest, q) == 0) return "\001"
    return substr(rest, 1, index(rest, q) - 1)
  }

  # `matching_mode` is a plain scalar (`strict` / `regex`), never quoted here.
  function extract_mode(it,   rest) {
    if (!match(it, /matching_mode[[:space:]]*:[[:space:]]*[A-Za-z]+/)) return "\001"
    rest = substr(it, RSTART, RLENGTH)
    sub(/^matching_mode[[:space:]]*:[[:space:]]*/, "", rest)
    return rest
  }

  # ---- entry boundaries -----------------------------------------------------
  # Whole-line comments only: an inline `#` here would be inside a quoted string
  # or a block scalar. Skipping them FIRST also keeps a comment between two list
  # items from being read as the end of the list.
  /^[[:space:]]*#/ { next }

  # Every `redirect_uris:` KEY in the file, however it is written. Compared at
  # the end against the number of lists actually parsed, so a flow-style or
  # oddly-indented list cannot pass by being invisible.
  /redirect_uris[[:space:]]*:/ { keys_in_file++ }

  # A top-level entry this parser does not recognise (e.g. a flow-map
  # `  - { model: ..., attrs: {...} }`) would carry providers past every check.
  /^  - / && !/^  - model:/ {
    fail("top-level entry written in a form this guard cannot parse: `" $0 "`. Blueprint entries " \
         "must be block-style `  - model: <model>` so every provider is examined.")
  }

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
  # Only the block form is understood; the list ends at the next sibling key.
  # Anything else INSIDE it (a Helm action, a stray indentation) is an error,
  # never a silent end-of-list — that was how a blank line or a `{{- if }}`
  # could hide every entry after it.
  /^      redirect_uris:[[:space:]]*$/ { in_uris = 1; lists_parsed++; next }
  in_uris && /^[[:space:]]*$/ { next }
  in_uris && /^        - / { push_item(); item = $0; next }
  in_uris && /^          [^[:space:]]/ { item = item " " $0; next }
  in_uris && /^      [A-Za-z_]/ { push_item(); in_uris = 0 }
  in_uris {
    push_item()
    fail("provider `" entry_id "` has a line inside `redirect_uris` this guard cannot read: `" \
         $0 "`. A Helm action or an unexpected indentation there would hide every entry after " \
         "it — write the list as plain `        - { ... }` items.")
    in_uris = 0
  }

  function push_item() {
    if (item != "") { items[++n_items] = item; item = "" }
  }

  # ---- per-provider assertions ----------------------------------------------
  function flush(   i, it, url, mode, n_authz) {
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
      if (count_url_keys(it) != 1) {
        fail("provider `" entry_id "` has a redirect URI entry with " count_url_keys(it) " `url:` " \
             "keys. Exactly one is readable: a duplicate key is silently resolved to the LAST by " \
             "the YAML loader while this guard reads the first.")
        continue
      }
      url = extract_url(it)
      if (url == "\001") {
        fail("provider `" entry_id "` has a redirect URI with no QUOTED `url:` value — this guard " \
             "(and review) reads that value; quote it.")
        continue
      }
      mode = extract_mode(it)
      if (mode == "\001") {
        fail("provider `" entry_id "` has a redirect URI with no `matching_mode:` — `strict` and " \
             "`regex` are different trust boundaries and this guard checks the pair.")
        continue
      }
      if (url == "http://localhost:.*") {
        fail("provider `" entry_id "` allow-lists `http://localhost:.*`. That fullmatches " \
             "`http://localhost:@evil.example`, which a browser resolves to evil.example with " \
             "`localhost:` as userinfo — the authorization code leaks to an attacker origin and " \
             "is redeemable with no secret and no PKCE verifier (#822). It also makes " \
             "`urlparse(...).port` raise inside `cors_allow`, 500ing a localhost Origin. Use a " \
             "STRICT literal naming one real dev port, e.g. `http://localhost:5175` — not a " \
             "narrower regex: `\\d` allow-lists unicode digits and `[0-9]` is a bracketed host " \
             "(see the header of this script).")
        continue
      }
      # `[`, `]` and `\d` are banned in EVERY redirect URI, of every type. Both
      # are real, separately-verified hazards, and neither is visible by
      # reading the pattern — checked before the allow-list so the message
      # names the hazard rather than just "not a reviewed form".
      if (index(url, "[") > 0 || index(url, "]") > 0) {
        fail("provider `" entry_id "` has redirect URI `" url "`, which contains a BRACKET. " \
             "authentik `urlparse()`s every redirect URI in `cors_allow` (providers/oauth2/" \
             "utils.py), and a bracketed netloc is parsed as an IPv6 literal: on Python 3.11.0 " \
             "`urlparse(\"http://localhost:[0-9]+(/.*)?\").hostname` is `0-9`, and later " \
             "CPython raises `ValueError: Invalid IPv6 URL`, which 500s the discovery document " \
             "for every request carrying an `Origin` header (it cost PR #823 a 30-minute k3d " \
             "run). Use a STRICT literal per dev port instead (#822, NFR-SEC-1).")
        continue
      }
      if (index(url, "\\d") > 0) {
        fail("provider `" entry_id "` has redirect URI `" url "`, which uses `\\d`. Python `\\d` " \
             "matches UNICODE decimal digits, so `http://localhost:٤٥` (Arabic-Indic 45) " \
             "fullmatches and is allow-listed while resolving to nothing like a port; and " \
             "`urlparse(\"http://localhost:\\d+(/.*)?\")` yields hostname `localhost` and then " \
             "RAISES on `.port`, which 500s /token and /userinfo for any localhost `Origin` " \
             "through `cors_allow`. Use a STRICT literal per dev port instead (#822, " \
             "NFR-SEC-1).")
        continue
      }
      if (!((mode " " url) in allowed))
        fail("provider `" entry_id "` allow-lists `" mode "` redirect `" url "`, which is not one " \
             "of the reviewed forms: `strict http://localhost:5175` / `strict " \
             "http://localhost:5174` (the Flutter and Vite dev servers — localhost dev origins " \
             "are STRICT literals, never a regex), `strict {{ .Values.global.appOrigin }}` / " \
             "`{{ ...adminOrigin }}`, or those same values as a regex WITH the " \
             "`| replace \".\" \"\\\\.\" }}/.*` dot-escape. Whole strings are compared on " \
             "purpose: an unescaped `.` in a host regex fullmatches a look-alike domain, and " \
             "every redirect URI is an authorization target OR a CORS origin on /token and " \
             "/userinfo (`token.py` builds that list from ALL redirect_uris, unfiltered). A NEW " \
             "DEV PORT is a deliberate edit to the allow-list at the top of this script, not a " \
             "wider pattern (#822, NFR-SEC-1).")
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
    if (keys_in_file != lists_parsed)
      fail("found " keys_in_file " `redirect_uris:` key(s) in the file but parsed " lists_parsed \
           " list(s). One is written in a form this guard does not read (a flow sequence, or a " \
           "different indentation), so its entries were never checked.")
    if (bad) exit 1
    printf "✓ [authorization-redirect] all %d provider redirect URI list(s) hold only reviewed forms: rendered origins or a strict localhost dev origin, and no `[`, `]` or `\\d` anywhere\n", lists_parsed
  }
' "${blueprint}"
