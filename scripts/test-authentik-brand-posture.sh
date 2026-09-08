#!/usr/bin/env bash
# Negative cases for scripts/check-authentik-brand-posture.sh (#648).
#
# A textual guard can stop looking without saying so — the same reason
# test-logout-invalidation-posture.sh and test-authorization-redirect-posture.sh run
# alongside their guards rather than on trust. Each case below is a way the Authentik
# surfaces silently go back to looking like a different product (or the branding stops
# being the app's own), applied to a COPY of the tree in a temp dir. Nothing here mutates
# the working tree.
#
# Also asserts the unmutated copy PASSES — a guard that fails on everything kills every
# mutant and protects nothing.
#
# Run by `task repo:authentik-brand-posture` -> `task repo:lint` -> `task ci`.
#
# Exit codes: 0 = every mutant rejected and the clean tree accepted, 1 = a gap.
#
# shellcheck disable=SC2016
# Every mutation below is a shell snippet passed to an inner `bash -c`, so its `$BP`/`$CV`/
# `$ET`/`$MK`/`$R` are DELIBERATELY single-quoted: they must expand in that inner shell
# against the temp-tree paths exported for it, not in this one.
set -uo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
guard="${repo_root}/scripts/check-authentik-brand-posture.sh"
chart_rel="infra/helm/beekeepingit/charts/authentik"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The exact set of files the guard reads. Rebuilt fresh per case so mutations never stack.
seed_tree() {
  local root="$1"
  rm -rf "${root}"
  mkdir -p "${root}/${chart_rel}/files/email" "${root}/${chart_rel}/templates" \
    "${root}/infra/helm/beekeepingit/environments" \
    "${root}/client/lib/theming" "${root}/client/web/icons"
  cp "${repo_root}/${chart_rel}/files/beekeepingit.blueprint.yaml" "${root}/${chart_rel}/files/"
  cp "${repo_root}/${chart_rel}/files/beekeepingit-mark.png" "${root}/${chart_rel}/files/"
  cp "${repo_root}/${chart_rel}/files/email/account_confirmation.html" "${root}/${chart_rel}/files/email/"
  cp "${repo_root}/${chart_rel}/values.yaml" "${root}/${chart_rel}/"
  cp "${repo_root}/${chart_rel}/templates/config-secret.yaml" "${root}/${chart_rel}/templates/"
  cp "${repo_root}/infra/helm/beekeepingit/values.yaml" "${root}/infra/helm/beekeepingit/"
  cp "${repo_root}"/infra/helm/beekeepingit/environments/*.yaml "${root}/infra/helm/beekeepingit/environments/"
  cp "${repo_root}/client/lib/theming/brand_tokens.dart" "${root}/client/lib/theming/"
  cp "${repo_root}/client/web/icons/Icon-192.png" "${root}/client/web/icons/"
}

killed=0
survived=0
accepted=0
false_positives=0

# expect_reject <description> <mutation shell snippet, with $R as the tree root>
expect_reject() {
  local desc="$1" mutation="$2"
  local root="${work}/case"
  seed_tree "${root}"
  R="${root}" BP="${root}/${chart_rel}/files/beekeepingit.blueprint.yaml" \
    CV="${root}/${chart_rel}/values.yaml" \
    CS="${root}/${chart_rel}/templates/config-secret.yaml" \
    ET="${root}/${chart_rel}/files/email/account_confirmation.html" \
    MK="${root}/${chart_rel}/files/beekeepingit-mark.png" \
    bash -c "${mutation}"
  if "${guard}" "${root}" >/dev/null 2>&1; then
    printf '✗ [authentik-brand/test] MUTANT SURVIVED: %s\n' "${desc}" >&2
    survived=$((survived + 1))
  else
    killed=$((killed + 1))
  fi
}

# expect_accept <description> <mutation shell snippet, with $R as the tree root>
# The mirror of expect_reject, for edits that are LEGITIMATE. A guard whose only test is
# "does it reject" drifts towards rejecting everything, and here that would be a real cost:
# these are the values #859 has to be free to choose from, so the guard has to stay a
# gatekeeper and not become the blocker.
expect_accept() {
  local desc="$1" mutation="$2"
  local root="${work}/case"
  seed_tree "${root}"
  R="${root}" BP="${root}/${chart_rel}/files/beekeepingit.blueprint.yaml" \
    CV="${root}/${chart_rel}/values.yaml" \
    CS="${root}/${chart_rel}/templates/config-secret.yaml" \
    ET="${root}/${chart_rel}/files/email/account_confirmation.html" \
    MK="${root}/${chart_rel}/files/beekeepingit-mark.png" \
    bash -c "${mutation}"
  if "${guard}" "${root}" >/dev/null 2>&1; then
    accepted=$((accepted + 1))
  else
    printf '✗ [authentik-brand/test] FALSE POSITIVE (a legitimate value was rejected): %s\n' "${desc}" >&2
    "${guard}" "${root}" >&2 || true
    false_positives=$((false_positives + 1))
  fi
}

# --- the entry itself ---------------------------------------------------------------------
expect_reject "brand entry removed (model renamed)" \
  'sed -i "s/^  - model: authentik_brands\.brand\$/  - model: authentik_brands.brandX/" "$BP"'
expect_reject "brand model name quoted (a different string to the importer)" \
  'sed -i "s/^  - model: authentik_brands\.brand\$/  - model: \"authentik_brands.brand\"/" "$BP"'
expect_reject "a second brand entry appended (last-wins)" \
  'printf "  - model: authentik_brands.brand\n    identifiers: { domain: authentik-default }\n    attrs: { branding_title: authentik }\n" >> "$BP"'
expect_reject "state: absent on the brand entry (deleted on apply)" \
  'sed -i "s/^    identifiers: { domain: authentik-default }\$/    state: absent\n    identifiers: { domain: authentik-default }/" "$BP"'
expect_reject "conditions: on the brand entry (gated off)" \
  'sed -i "s/^    identifiers: { domain: authentik-default }\$/    conditions: [false]\n    identifiers: { domain: authentik-default }/" "$BP"'
expect_reject "brand entry re-pointed at another domain" \
  'sed -i "s/domain: authentik-default/domain: example-default/" "$BP"'
expect_reject "branding_title back to authentik" \
  'sed -i "s/^      branding_title: BeekeepingIT\$/      branding_title: authentik/" "$BP"'
expect_reject "branding_custom_css emptied" \
  'sed -i "s/^      branding_custom_css: |\$/      branding_custom_css: \"\"/" "$BP"'

# --- the honey primary action --------------------------------------------------------------
expect_reject "primary button back to a Bootstrap blue" \
  'sed -i "s/\.pf-c-button\.pf-m-primary{background:#F0A81F/.pf-c-button.pf-m-primary{background:#0066CC/" "$BP"'
expect_reject "primary-button rule deleted outright" \
  'sed -i "/^        \.pf-c-button\.pf-m-primary{background:/d" "$BP"'

# --- brand values stay tokens ---------------------------------------------------------------
expect_reject "an invented ground hex on the flow pages" \
  'sed -i "s/#221D31!important;background-image:none/#1a120b!important;background-image:none/" "$BP"'
expect_reject "an invented hex in the branded email" \
  'sed -i "s/#F6F3EC/#EFEAE0/g" "$ET"'

# --- the two silent rewrites found in review -------------------------------------------------
expect_reject "a child combinator in the CSS (authentik rewrites > to a literal \\u003E)" \
  'sed -i "s/\.pf-c-login__main-footer-links-item a/.pf-c-login__main-footer-links-item>a/" "$BP"'
expect_reject "an @import in the CSS (off-origin fetch on the password page)" \
  'sed -i "s|^        \.pf-c-login__footer|        @import url(https://fonts.googleapis.com/css2?family=Archivo);\n        .pf-c-login__footer|" "$BP"'
expect_reject "a webfont added next to the inlined mark" \
  'sed -i "s|^        \.pf-c-login__footer|        @font-face{font-family:Archivo;src:url(https://fonts.gstatic.com/s/archivo.woff2)}\n        .pf-c-login__footer|" "$BP"'
expect_reject "the blocktrans block re-indented to match the surrounding HTML (msgid miss)" \
  'sed -i "s/^    {% blocktrans with url=url %}/                {% blocktrans with url=url %}/" "$ET"'

# --- the mark ---------------------------------------------------------------------------------
expect_reject ".Files.Get path renamed (renders an EMPTY data URI, no error)" \
  'sed -i "s|files/beekeepingit-mark.png|files/missing-mark.png|" "$BP"'
expect_reject "logo swapped for a remote URL (off-origin fetch on the password page)" \
  'sed -i "s|url(\"data:image/png;base64.*b64enc }}\")|url(\"https://example.invalid/logo.png\")|" "$BP"'
expect_reject "chart copy of the mark drifts from the client icon" \
  'printf drift >> "$MK"'

# --- the email override ------------------------------------------------------------------------
expect_reject "AUTHENTIK_EMAIL__TEMPLATE_DIR dropped (branded template goes inert)" \
  'sed -i "/AUTHENTIK_EMAIL__TEMPLATE_DIR/d" "$CS"'
expect_reject "templateDir dropped from chart values" \
  'sed -i "/^  templateDir:/d" "$CV"'
expect_reject "templateDir moved off /templates (breaks the gitops mount, #858)" \
  'sed -i "s|^  templateDir: /templates\$|  templateDir: /srv/templates|" "$CV"'
expect_reject "email msgid reworded into plain English (untranslated for pt-PT)" \
  "sed -i \"s/{% trans 'Welcome!' %}/Welcome to BeekeepingIT!/\" \"\$ET\""
expect_reject "blocktrans link msgid reworded" \
  'sed -i "s/If that doesn.t work, copy and paste the following link in your browser: {{ url }}/Link: {{ url }}/" "$ET"'
expect_reject "branded email template deleted" \
  'rm -f "$ET"'

# --- the sender -----------------------------------------------------------------------------------
expect_reject "fromName removed" \
  'sed -i "/^  fromName: BeekeepingIT\$/d" "$CV"'
expect_reject "fromName is not the product name" \
  'sed -i "s/^  fromName: BeekeepingIT\$/  fromName: authentik/" "$CV"'
expect_reject "sender un-split back to a single from: key" \
  'sed -i "s/^  fromAddress: no-reply@beekeepingit.local\$/  from: no-reply@beekeepingit.local/" "$CV"'
expect_reject "retired from: key reintroduced in an environment overlay" \
  'printf "\nauthentik:\n  email:\n    from: no-reply@example.com\n" >> "$R/infra/helm/beekeepingit/environments/staging.yaml"'
expect_reject "AUTHENTIK_EMAIL__FROM no longer composed from name + address" \
  'sed -i "s|^  AUTHENTIK_EMAIL__FROM:.*|  AUTHENTIK_EMAIL__FROM: {{ .fromAddress \| quote }}|" "$CS"'

# --- the brand's image FileFields (#859) -------------------------------------------------------------
# Every one of these is a value someone could reasonably reach for to brand the browser-tab
# favicon, and every one of them fails Authentik's `validate_file_name` — which does not lose
# an icon, it rolls the WHOLE blueprint back (Importer.apply is atomic: no provider, no
# application, no login). The guard has to be the thing that says so, because on a feature
# branch nothing else can.
expect_reject "branding_favicon as a data: URI (the guess #648's comment warned about)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: data:image/png;base64,AAAA\n      branding_title: BeekeepingIT|" "$BP"'
expect_reject "branding_favicon as an absolute pod path (rides the #858 mount)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: /templates/email/favicon.png\n      branding_title: BeekeepingIT|" "$BP"'
expect_reject "branding_logo as a Helm expression the guard cannot evaluate" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_logo: \"{{ .Values.global.appOrigin }}/icons/Icon-192.png\"\n      branding_title: BeekeepingIT|" "$BP"'
expect_reject "branding_default_flow_background emptied" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_default_flow_background: \"\"\n      branding_title: BeekeepingIT|" "$BP"'
expect_reject "branding_favicon with a parent-directory escape" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: ../etc/passwd\n      branding_title: BeekeepingIT|" "$BP"'
# Authentik ACCEPTS these two; this deployment must not. An off-origin subresource on the
# credential page is a per-sign-in request logged by whoever serves it (NFR-SEC-1) — the same
# invariant that keeps the mark inlined and a Google Fonts <link> out of the CSS.
expect_reject "branding_favicon on another origin (off-origin fetch on the password page)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: https://app.beekeepingit.local:8443/favicon.png\n      branding_title: BeekeepingIT|" "$BP"'
expect_reject "branding_logo over plaintext http (the validator's prefix test is literally http:)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_logo: http://example.test/logo.svg\n      branding_title: BeekeepingIT|" "$BP"'

# ...and the three shapes the serializer DOES accept must not be rejected — a guard that says
# no to everything would just move #859's blocker from the cluster to the lint gate.
expect_accept "branding_favicon as a /static path (StaticBackend)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: /static/dist/assets/icons/icon.png\n      branding_title: BeekeepingIT|" "$BP"'
expect_accept "branding_favicon as a relative media name (FileBackend)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: beekeepingit-favicon.png\n      branding_title: BeekeepingIT|" "$BP"'
expect_accept "branding_logo as an fa:// icon (bundled Font Awesome, no fetch)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_logo: fa://fa-hive\n      branding_title: BeekeepingIT|" "$BP"'
expect_accept "branding_favicon as a themed media name (%(theme)s is folded before the charset check)" \
  'sed -i "s|^      branding_title: BeekeepingIT\$|      branding_favicon: icons/favicon-%(theme)s.png\n      branding_title: BeekeepingIT|" "$BP"'

# --- and the clean tree must PASS ------------------------------------------------------------------
clean="${work}/clean"
seed_tree "${clean}"
if ! "${guard}" "${clean}" >/dev/null 2>&1; then
  printf '✗ [authentik-brand/test] the UNMUTATED tree is rejected — the guard fails on everything\n' >&2
  "${guard}" "${clean}" >&2 || true
  exit 1
fi

if [ "${survived}" -ne 0 ] || [ "${false_positives}" -ne 0 ]; then
  printf '✗ [authentik-brand/test] %s of %s mutants survived; %s of %s legitimate values rejected\n' \
    "${survived}" "$((killed + survived))" \
    "${false_positives}" "$((accepted + false_positives))" >&2
  exit 1
fi
printf '✓ [authentik-brand/test] %s mutants rejected, %s legitimate values accepted, clean tree accepted\n' \
  "${killed}" "${accepted}"
