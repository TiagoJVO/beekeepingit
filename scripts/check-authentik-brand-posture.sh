#!/usr/bin/env bash
# Guard: every Authentik surface a user passes through stays BeekeepingIT-branded,
# and every brand value stays the app's own (#648, FR-ONB-1, FR-UX-1, NFR-SEC-1, D-18).
#
# WHY A GUARD AND NOT JUST A REVIEW. The branding is the security control here, not
# decoration: the sign-in page is the ONE moment in the product where a user types a
# password, and it happens on a different hostname than the app. Stock Authentik chrome on
# that page — the red wordmark, the stock photograph, a Bootstrap-blue primary button — is
# indistinguishable from a phishing hop to the person looking at it. Every failure mode
# below is silent: the page still renders, the login still works, it just stops looking
# like this product.
#
#   1. ONE BRAND ROW, LIVE. `authentik_brands.brand` for `domain: authentik-default` skins
#      EVERY page authentik renders — the sign-in flow, the enrolment flow, the flow
#      executor's post-submit end pages and the Django-rendered static pages. So the whole
#      acceptance criterion rides on a single entry, and the blueprint has three documented
#      ways to leave an entry looking present while it does nothing (see
#      check-logout-invalidation-posture.sh, which found each of them live): `state: absent`
#      deletes it on apply, `conditions:` can gate it off, and a quoted model name is a
#      DIFFERENT string to the importer's model lookup. A second brand entry is worse than
#      none — last-wins, silently.
#
#   2. THE PRIMARY ACTION IS HONEY. `docs/design/prototype.md`'s "honey is the only primary
#      action" rule is enforced in the client by BrandTokens/AppTheme and by a contrast
#      test; nothing enforced it on the IdP's page, which is why the primary control in the
#      auth flow was Bootstrap blue for as long as it was. Asserted on the rule that
#      actually paints it (`.pf-c-button.pf-m-primary`), not on "the file mentions honey".
#
#   3. NO INVENTED BRAND VALUES. The CSS this replaced used #E8B979 on #1a120b — two hexes
#      that appear NOWHERE in the app. They read as brand colours and were nobody's brand.
#      So every hex on these two surfaces must be a token in
#      client/lib/theming/brand_tokens.dart, which is the file that carries the measured
#      contrast ratios and the role rules. This is the assertion that keeps "where did this
#      colour come from" answerable a year from now.
#
#   4. THE MARK IS THE APP'S MARK, INLINE. The logo is the PWA's own icon, inlined as a
#      data URI through `.Files.Get` — inline because the password-entry page must fetch
#      NOTHING from a third party or from another origin (NFR-SEC-1), and because a remote
#      logo turns the login page into a dependency on the app's static hosting. Helm's
#      `.Files.Get` returns the EMPTY STRING for a path that is not in the chart and raises
#      nothing, so a moved or renamed file ships `url("data:image/png;base64,")` — a login
#      page with no logo, and a green render. The copy is also checked byte-for-byte against
#      the client's icon: a chart cannot read files outside itself, so the duplicate is
#      unavoidable, and an unguarded duplicate drifts.
#
#   5. THE EMAIL OVERRIDE STAYS AN OVERRIDE, AND STAYS TRANSLATED. The branded
#      account-confirmation template only takes effect because Django searches
#      `TEMPLATES[0]["DIRS"]` — `[CONFIG.get("email.template_dir")]` — before the per-app
#      loader; drop `AUTHENTIK_EMAIL__TEMPLATE_DIR` and the branded file is inert with no
#      error anywhere. And the mail is translated only because every visible string is one
#      of authentik's OWN msgids: a rewritten line is untranslated text in a message that
#      pt_PT currently renders in full (NFR-I18N-1, D-34, #412).
#
#   6. THE SENDER IS NAMED AND ITS ADDRESS IS DECLARED A PLACEHOLDER. Choosing a real
#      sending domain belongs to #417, so this guard does not assert a domain — it asserts
#      that the field is still SPLIT (so #417 sets one value), that the display name is the
#      product name, and that the retired single `from:` key has not come back anywhere in
#      this repo's values, where it would be silently ignored by the template.
#
#   7. THE BRAND'S IMAGE FIELDS CARRY A VALUE THE SERIALIZER ACCEPTS. `branding_logo`,
#      `branding_favicon` and `branding_default_flow_background` are
#      `authentik.admin.files.fields.FileField` — a `TextField` whose
#      `default_validators = [validate_file_name]` (authentik/admin/files/validation.py, read
#      at the pinned 2026.5.4). Getting one wrong does not merely lose an icon: the
#      blueprint's `Importer.apply` is ATOMIC, so a rejected value rolls the WHOLE file back —
#      no OAuth2 provider, no application, no login, on every environment that reconciles it.
#      #648 left the three fields at their defaults for exactly that reason and #859 decides
#      what they should carry; this check makes the day one of them IS set a change the lint
#      gate can judge, instead of one only a live cluster can. It asserts nothing about
#      WHETHER they are set.
#
# Deterministic and offline: asserts over the chart SOURCE, no cluster, and no YAML parser
# (the blueprint carries custom `!KeyOf`/`!Find`/`!Env` tags and Go template expressions
# that a plain parser rejects). Same engine style as
# scripts/check-logout-invalidation-posture.sh.
#
# Run by `task repo:authentik-brand-posture` -> `task repo:lint` -> `task ci`.
# Written up in docs/architecture/auth.md §8.19 (rules 1-6) and §8.20 (rule 7 + the
# `templateDir` cross-repo contract).
#
# Exit codes: 0 = branding intact, 1 = drift.
set -euo pipefail

# An optional argument overrides the tree this guard reads — used ONLY by
# scripts/test-authentik-brand-posture.sh, which builds mutated copies of the handful of
# files below in a temp dir. Same "fixture path" affordance the sibling guards expose, just
# rooted a level higher because this posture spans the blueprint, the chart values, the
# config Secret, the email template and two image files.
repo_root="${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
chart="${repo_root}/infra/helm/beekeepingit/charts/authentik"
blueprint="${chart}/files/beekeepingit.blueprint.yaml"
chart_values="${chart}/values.yaml"
config_secret="${chart}/templates/config-secret.yaml"
email_template="${chart}/files/email/account_confirmation.html"
mark_chart="${chart}/files/beekeepingit-mark.png"
mark_source="${repo_root}/client/web/icons/Icon-192.png"
tokens="${repo_root}/client/lib/theming/brand_tokens.dart"

fail() {
  printf '✗ [authentik-brand] %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '  %s\n' "${line}" >&2; done
  exit 1
}

for f in "${blueprint}" "${chart_values}" "${config_secret}" "${email_template}" \
  "${mark_chart}" "${mark_source}" "${tokens}"; do
  [ -f "${f}" ] || fail "missing file: ${f}"
done

# --- (1) exactly one live brand entry -----------------------------------------------------
# Walked by indentation from the `- model:` line to the next entry, so a `state:`/
# `conditions:` key belonging to a NEIGHBOURING entry can never be mistaken for this one's.
brand_block="$(awk '
  /^  - model:/ { inbrand = ($3 == "authentik_brands.brand") }
  inbrand { print }
' "${blueprint}")"

brand_count="$(grep -cE '^  - model:[[:space:]]+authentik_brands\.brand[[:space:]]*$' "${blueprint}" || true)"
[ "${brand_count}" = "1" ] || fail \
  "expected exactly ONE unquoted \`- model: authentik_brands.brand\` entry, found ${brand_count}." \
  "A second entry silently wins (last-wins on apply); zero entries means the sign-in," \
  "enrolment, post-submit and post-logout pages all fall back to stock authentik chrome." \
  "A QUOTED model name is a different string to the importer and is not counted here."

if printf '%s\n' "${brand_block}" | grep -qE '^[[:space:]]*(state|conditions):'; then
  fail "the brand entry carries a \`state:\` or \`conditions:\` key." \
    "\`state: absent\` deletes the brand on apply and \`conditions:\` can gate it off —" \
    "either one un-brands every flow page while the entry still reads as present."
fi

# Tolerant of both YAML spellings — the entry uses the inline-flow form
# (`identifiers: { domain: authentik-default }`) today, but a reflow to block style must not
# read as drift.
printf '%s\n' "${brand_block}" | grep -qE '[{,[:space:]]domain:[[:space:]]*["'\'']?authentik-default["'\'']?[[:space:]]*[},]?[[:space:]]*$' || fail \
  "the brand entry no longer identifies \`domain: authentik-default\`." \
  "That is the row authentik resolves for every flow page; another domain skins nothing."

for key in branding_title branding_custom_css; do
  n="$(printf '%s\n' "${brand_block}" | grep -cE "^[[:space:]]*${key}:" || true)"
  [ "${n}" = "1" ] || fail "brand entry sets \`${key}\` ${n} times; expected exactly 1." \
    "Duplicate keys are last-wins in PyYAML and raise nothing."
done

printf '%s\n' "${brand_block}" | grep -qE '^[[:space:]]*branding_title:[[:space:]]*["'\'']?BeekeepingIT["'\'']?[[:space:]]*$' || fail \
  "\`branding_title\` is not BeekeepingIT — the browser tab and page title name the IdP instead."

# --- the CSS block scalar, isolated by indentation ----------------------------------------
css="$(printf '%s\n' "${brand_block}" | awk '
  /^[[:space:]]*branding_custom_css:[[:space:]]*\|[[:space:]]*$/ {
    match($0, /^[[:space:]]*/); key_indent = RLENGTH; incss = 1; next
  }
  incss {
    if ($0 ~ /^[[:space:]]*$/) { print; next }
    match($0, /^[[:space:]]*/)
    if (RLENGTH <= key_indent) { incss = 0; next }
    print
  }
')"
[ -n "${css}" ] || fail "\`branding_custom_css\` is empty or is not a \`|\` block scalar." \
  "It is the ONLY branding channel on these pages (the logo/favicon/background fields are" \
  "Django FileFields naming files this repo cannot put in the authentik pod), so an empty" \
  "value is a fully stock login page."

# --- (2) the primary action is honey, not authentik's blue --------------------------------
primary_rule="$(printf '%s\n' "${css}" | grep -F '.pf-c-button.pf-m-primary{' || true)"
[ -n "${primary_rule}" ] || fail \
  "no \`.pf-c-button.pf-m-primary{...}\` rule — the primary control on the sign-in and" \
  "enrolment pages falls back to authentik's Bootstrap blue, which is the 'one honey" \
  "primary action' rule broken on the one page where a password is typed."
case "${primary_rule}" in
  *"background:#F0A81F"*) : ;;
  *) fail "the primary button is not filled with BrandTokens.honey (#F0A81F)." \
      "That fill is the app's own PrimaryActionButton colour; anything else makes the" \
      "primary action of the auth flow a different colour from the primary action of the app." ;;
esac

# --- (3) no invented brand values: every hex is a token ------------------------------------
# Both branded surfaces are checked with one loop — the flow CSS and the email template.
hexes="$(printf '%s\n%s\n' "${css}" "$(cat "${email_template}")" \
  | grep -oE '#[0-9A-Fa-f]{6}' | tr '[:lower:]' '[:upper:]' | sort -u)"
[ -n "${hexes}" ] || fail "no colours found on the branded surfaces at all."
while IFS= read -r hex; do
  [ -n "${hex}" ] || continue
  if ! grep -qiE "Color\(0xFF${hex#\#}\)" "${tokens}"; then
    fail "colour ${hex} is not a token in client/lib/theming/brand_tokens.dart." \
      "Brand hexes are defined once, in that file, with their measured contrast ratios and" \
      "role rules; a hex that lives only here is exactly the #E8B979/#1a120b situation #648" \
      "replaced — a colour that reads as the brand and is nobody's brand. Add the token" \
      "there first (or use an existing one), then use it here."
  fi
done <<EOF
${hexes}
EOF

# --- (3a) no `<`, `>` or `&` — authentik rewrites them and the rule dies silently ----------
# authentik serves this field through
# `mark_safe(custom_css.translate(_json_script_escapes))` (brands/utils.py) into a `<style>`
# element, and Django's `_json_script_escapes` maps `<`, `>` and `&` to the literal
# sequences `<`, `>`, `&`. CSS reads `\u` as an escaped literal `u`, so a
# child combinator arrives as part of a class name: `.foo>a` becomes `.foou003Ea`, which
# matches nothing — valid CSS, no console error, rule gone. That is exactly the failure mode
# this guard exists for, and it cost the D-18 hit-target floor on the flow footer links once
# already (infra review, #648).
badchars="$(printf '%s\n' "${css}" | grep -nE '[<>&]' || true)"
if [ -n "${badchars}" ]; then
  fail "the brand CSS contains \`<\`, \`>\` or \`&\`: ${badchars}" \
    "authentik rewrites all three to literal \\u003C / \\u003E / \\u0026 before the browser" \
    "parses them, so the rule survives as text and matches nothing. Use a descendant" \
    "selector instead of a child combinator, and spell any entity another way."
fi

# --- (3b) the branded page fetches NOTHING off-origin ---------------------------------------
# The blueprint's typography comment says a Google Fonts <link> on the password page would
# leak every sign-in to a third party — but nothing stopped one being ADDED. Pinning the logo
# line (below) only rejects REPLACING the inlined mark; an `@import`, a webfont `src:`, or a
# second `url(https://…)` next to it would sail through. So: no `@import` at all, and every
# `url(` in the block must open with `data:`.
if printf '%s\n' "${css}" | grep -qiF '@import'; then
  fail "the brand CSS contains an \`@import\` — the sign-in page would fetch it at load." \
    "This is the password-entry page: it must pull nothing from a third party or from" \
    "another origin (NFR-SEC-1). Inline the content instead."
fi
offsite="$(printf '%s\n' "${css}" | grep -oE 'url\(["'\'']?[^)"'\'']*' | grep -viE 'url\(["'\'']?data:' || true)"
if [ -n "${offsite}" ]; then
  fail "the brand CSS references a non-\`data:\` URL: ${offsite}" \
    "Every asset on the sign-in page is inlined on purpose — an off-origin fetch leaks the" \
    "sign-in to whoever serves it, and makes the login page fail when that host is down."
fi

# --- (4) the mark is the app's mark, inlined through .Files.Get ---------------------------
printf '%s\n' "${css}" | grep -qF 'url("data:image/png;base64,{{ .Files.Get "files/beekeepingit-mark.png" | b64enc }}")' || fail \
  "the brand mark is no longer inlined from \`files/beekeepingit-mark.png\` via \`.Files.Get\`." \
  "A remote URL would make the password page fetch from another origin (NFR-SEC-1) and" \
  "depend on that origin being up; a changed path renders an EMPTY data URI, because" \
  "Helm's .Files.Get returns \"\" for a missing path and raises nothing."
cmp -s "${mark_chart}" "${mark_source}" || fail \
  "files/beekeepingit-mark.png has drifted from client/web/icons/Icon-192.png." \
  "A Helm chart cannot read files outside itself, so the copy is unavoidable — but an" \
  "unguarded copy means the login page keeps showing the OLD app icon after a rebrand." \
  "Re-copy it: cp client/web/icons/Icon-192.png ${mark_chart#"${repo_root}/"}"

# --- (5) the email override is wired, and stays on authentik's msgids ---------------------
grep -qE '^[[:space:]]*AUTHENTIK_EMAIL__TEMPLATE_DIR:' "${config_secret}" || fail \
  "config-secret.yaml no longer renders AUTHENTIK_EMAIL__TEMPLATE_DIR." \
  "Without it Django never searches the mounted directory, the branded template is inert," \
  "and authentik's own account-confirmation mail goes out with nothing to show for it."
# The VALUE, not just the key. `/templates` is half of a CROSS-REPO contract: the Authentik
# workload is an external Flux HelmRelease in beekeepingit-gitops (ADR-0012/ADR-0016), and
# since #858 that release mounts `beekeepingit-authentik-email-templates` at
# `/templates/email` — one directory BELOW this value, because Django resolves the template
# by the name the email stage asks for (`email/account_confirmation.html`) and a ConfigMap
# key cannot contain `/`. Move this value on its own and the mount lands somewhere Django
# never searches: Authentik's built-in template renders, the mail still goes out, and
# nothing in EITHER repo says so. Changing it needs a paired PR against beekeepingit-gitops.
grep -qE '^[[:space:]]*templateDir:[[:space:]]*/templates[[:space:]]*$' "${chart_values}" || fail \
  "authentik.email.templateDir is not \`/templates\` (or is gone) — see AUTHENTIK_EMAIL__TEMPLATE_DIR." \
  "That path is half of a cross-repo contract: beekeepingit-gitops mounts the" \
  "beekeepingit-authentik-email-templates ConfigMap at \`/templates/email\` on the Authentik" \
  "server and worker (#858). Changing it here without the paired change there silently" \
  "un-brands the mail — Django falls back to Authentik's own template and still sends."

# Byte-for-byte against the msgids in authentik's own template, which is what keeps the
# pt_PT catalogue matching. Any rewording here ships untranslated English to a pt-PT user.
while IFS= read -r msgid; do
  grep -qF "${msgid}" "${email_template}" || fail \
    "the branded email no longer carries authentik's msgid: ${msgid}" \
    "Visible strings in this template MUST be authentik's own msgids — they are the only" \
    "reason the shipped pt_PT catalogue translates this mail (#412, NFR-I18N-1, D-34)." \
    "Rewriting one silently makes that line English for every Portuguese recipient."
done <<'MSGIDS'
{% trans 'Welcome!' %}
{% trans "We're excited to have you get started. First, you need to confirm your account. Just press the button below."%}
{% trans 'Confirm Account' %}
MSGIDS

# The `blocktrans` block is checked WHOLE, INDENTATION INCLUDED — a substring grep passes at
# any indentation and this one is not indentation-independent. Django builds a blocktrans
# msgid from the literal text between the tags (`BlockTranslateNode.render_token_list`
# concatenates the raw tokens and trims only when `trimmed` is given), and the shipped
# pt_PT catalogue's entry is upstream's `\n` + FOUR spaces + text + `\n` + four spaces. Nest
# these three lines to match the surrounding HTML and the msgid becomes one no catalogue
# has: gettext falls back to the msgid and the line is English for every pt-PT recipient,
# with no warning anywhere. Found in review on the first draft of this template, which
# indented them to 16.
expected_blocktrans="$(printf '%s\n' \
  "    {% blocktrans with url=url %}" \
  "    If that doesn't work, copy and paste the following link in your browser: {{ url }}" \
  "    {% endblocktrans %}")"
# Pulled as three CONSECUTIVE lines (a substring grep would accept them scattered, and a
# multi-line `grep -F` pattern is matched per line, never as a block).
actual_blocktrans="$(awk '
  /^    \{% blocktrans with url=url %\}$/ { n = 3 }
  n-- > 0 { print }
' "${email_template}")"
if [ "${actual_blocktrans}" != "${expected_blocktrans}" ]; then
  fail "the branded email's \`{% blocktrans %}\` block is not upstream's exact text AND indentation." \
    "The msgid INCLUDES the surrounding whitespace, and the pt_PT catalogue carries the" \
    "4-space-indented form. Re-indenting these three lines to sit neatly inside the table" \
    "silently makes that line English for every Portuguese recipient. Expected, verbatim:" \
    "${expected_blocktrans}"
fi

# --- (6) the sender stays split, named, and placeholder-marked -----------------------------
grep -qE '^[[:space:]]*fromName:[[:space:]]*BeekeepingIT[[:space:]]*$' "${chart_values}" || fail \
  "authentik.email.fromName is not BeekeepingIT — the inbox line goes back to a bare address."
grep -qE '^[[:space:]]*fromAddress:' "${chart_values}" || fail \
  "authentik.email.fromAddress is gone; #417 needs exactly one value to set per environment."
from_line="$(grep -E '^[[:space:]]*AUTHENTIK_EMAIL__FROM:' "${config_secret}" || true)"
case "${from_line}" in
  *.fromName*.fromAddress*) : ;;
  *) fail "AUTHENTIK_EMAIL__FROM is no longer composed from fromName + fromAddress." \
      "Rendering the bare address drops the display name, which is the branding half of the" \
      "sender — the inbox line goes back to reading as a bare address on an unfamiliar" \
      "domain, which is the same phishing-shaped hand-off one surface further on." ;;
esac

legacy="$(grep -rlnE '^[[:space:]]*from:[[:space:]]*[^[:space:]#]+@' \
  "${chart_values}" "${repo_root}/infra/helm/beekeepingit/values.yaml" \
  "${repo_root}/infra/helm/beekeepingit/environments" 2>/dev/null || true)"
[ -z "${legacy}" ] || fail \
  "a retired \`from: <address>\` key is back in: ${legacy}" \
  "The chart template rejects it outright at render time; use fromName + fromAddress."

# --- (7) the brand's image fields carry a value the serializer accepts ---------------------
# Mirrors `validate_file_name` (authentik/admin/files/validation.py @ 2026.5.4), which accepts
# a value in exactly three shapes and rejects everything else:
#
#   /static…                      -> StaticBackend  (served from the pod's web/dist)
#   http:… | https://… | fa://…   -> PassthroughBackend (returned to the browser verbatim)
#   otherwise a RELATIVE upload name -> the media file backend, i.e. a file that has to exist
#     in Authentik's own storage: `^[a-zA-Z0-9._/-]+$` (after `%(theme)s` is folded to a word),
#     no `//`, no `..` component, not absolute, not starting with `.`
#
# This guard accepts a NARROWER set than authentik does: `http:`/`https://` is rejected here
# because these fields render on the credential page, which fetches nothing off-origin
# (NFR-SEC-1) — see the rule itself for the argument.
#
# So a `data:` URI is rejected — the charset alone kills the `:` and `;` — and so is an
# absolute pod path such as `/templates/email/favicon.png`. Both are the plausible guesses,
# and both would take the whole blueprint down with them. This check is deliberately silent
# when the fields are absent (their default is the shipped `/static/...` icon), so it costs
# nothing until #859 lands a value.
for key in branding_logo branding_favicon branding_default_flow_background; do
  line="$(printf '%s\n' "${brand_block}" | grep -E "^[[:space:]]*${key}:" || true)"
  [ -n "${line}" ] || continue

  n="$(printf '%s\n' "${line}" | wc -l | tr -d '[:space:]')"
  [ "${n}" = "1" ] || fail "brand entry sets \`${key}\` ${n} times; expected at most 1." \
    "Duplicate keys are last-wins in PyYAML and raise nothing."

  # Strip the key, surrounding whitespace and one layer of YAML quoting.
  value="$(printf '%s\n' "${line}" \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]*\$//; s/^\"(.*)\"\$/\1/; s/^'(.*)'\$/\1/")"

  case "${value}" in
    *'{{'*) fail "\`${key}\` is a Helm expression, not a literal: ${value}" \
        "This guard cannot evaluate one, and an unevaluatable value here is exactly the case" \
        "that only a live cluster can judge — which is what makes it dangerous: a value" \
        "Authentik's serializer rejects fails the WHOLE blueprint atomically (no provider, no" \
        "application, no login), not just this icon. Use a literal." ;;
    "" | "|" | ">" | "|-" | ">-") fail "\`${key}\` is empty or a block scalar: ${value}" \
        "\`validate_file_name\` rejects an empty name outright, and a multi-line value is not" \
        "a file name. That failure takes the whole blueprint down with it." ;;
  esac

  # Shape 2, NARROWED. `http:`/`https://` is a shape authentik accepts and this deployment
  # does not (security review, #859). These three fields render into `base/skeleton.html` as
  # `<link rel="icon" href="…">` etc. on the SIGN-IN page, and `auth.<env>` is a different
  # origin from `app.<env>`: an off-origin subresource there is a request logged by whoever
  # serves it on every single sign-in — client IP, UA, timestamp — and, because the two hosts
  # are same-SITE, `SameSite=Lax` cookies ride along with it, correlating "this browser" with
  # "is on the credential page now". It is the same invariant the blueprint's typography
  # comment already states for a Google Fonts `<link>`, and the reason the brand mark is
  # inlined as a data URI. That posture lived only in prose while this guard waved an
  # `https://` value straight through. (Note also that the validator's prefix test is
  # literally `http:`, so a PLAINTEXT URL passes it server-side and is stopped only by the
  # browser's mixed-content block.)
  case "${value}" in
    http:* | https://*) fail "\`${key}: ${value}\` points the sign-in page at another origin." \
        "Authentik accepts it; this deployment does not. The sign-in page is the one page in" \
        "the product where a password is typed, and it must fetch NOTHING off-origin" \
        "(NFR-SEC-1) — an off-origin favicon is a per-sign-in request logged by whoever serves" \
        "it, carried with same-site cookies, and it makes the credential page depend on that" \
        "host being up. Use a \`/static…\` path or a relative media name served by the" \
        "Authentik pod itself. See #859 and docs/architecture/auth.md §8.20." ;;
  esac

  # Shape 1 (+ `fa://`, which the web UI resolves to a bundled Font Awesome class and fetches
  # nothing for): accepted as-is.
  case "${value}" in
    /static* | fa://*) continue ;;
  esac

  # Shape 3: a relative upload name. `%(theme)s` is folded to a plain word first, exactly as
  # the validator does, so a themed name is not rejected for its parentheses.
  probe="$(printf '%s' "${value}" | sed 's/%(theme)s/theme/g')"
  bad=""
  printf '%s' "${probe}" | grep -qE '^[A-Za-z0-9._/-]+$' \
    || bad="only letters, digits, '.', '-', '_', '/' and the %(theme)s placeholder are allowed"
  case "${value}" in
    *//*) bad="a duplicate '/' is rejected" ;;
  esac
  case "${probe}" in
    /*) bad="an absolute path is rejected — the pod's own filesystem is NOT reachable this way" ;;
    .. | ../* | */.. | */../*) bad="a '..' component is rejected" ;;
    .*) bad="a name starting with '.' is rejected" ;;
  esac
  [ -z "${bad}" ] || fail \
    "\`${key}: ${value}\` is not a value Authentik's serializer accepts — ${bad}." \
    "\`FileField\`'s validate_file_name takes only: a \`/static…\` path, an" \
    "\`http:\`/\`https://\`/\`fa://\` URL, or a RELATIVE media file name" \
    "(^[a-zA-Z0-9._/-]+\$, no //, no .., not absolute, not leading '.'). A \`data:\` URI and an" \
    "absolute pod path are both rejected. And a rejected value does not merely lose the icon:" \
    "Importer.apply is atomic, so the WHOLE blueprint rolls back — no OAuth2 provider, no" \
    "application, no login. See #859 and docs/architecture/auth.md §8.20."
done

printf '✓ [authentik-brand] flow pages + confirmation email carry BeekeepingIT branding, every hex is a brand token, sender stays split for #417\n'
