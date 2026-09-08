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

# --- and the clean tree must PASS ------------------------------------------------------------------
clean="${work}/clean"
seed_tree "${clean}"
if ! "${guard}" "${clean}" >/dev/null 2>&1; then
  printf '✗ [authentik-brand/test] the UNMUTATED tree is rejected — the guard fails on everything\n' >&2
  "${guard}" "${clean}" >&2 || true
  exit 1
fi

if [ "${survived}" -ne 0 ]; then
  printf '✗ [authentik-brand/test] %s of %s mutants survived\n' \
    "${survived}" "$((killed + survived))" >&2
  exit 1
fi
printf '✓ [authentik-brand/test] %s mutants rejected, clean tree accepted\n' "${killed}"
