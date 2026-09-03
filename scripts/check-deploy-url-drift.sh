#!/usr/bin/env bash
# Fail when the per-environment PWA URLs drift between their two copies (#369, D-27).
#
# The PWA's OIDC/gateway/PowerSync URLs are Dart *compile-time* constants, so
# .github/workflows/release-deploy.yml's `publish-client` job bakes the target
# environment's URLs into the image via --dart-define. The very same hostnames also
# live in infra/helm/beekeepingit/environments/<env>.yaml, which configures the
# cluster the image is then served from. Nothing derives one from the other, so a
# one-sided edit silently ships a PWA that talks to the wrong host.
#
# This script does NOT restructure where deploy values come from (that path can't be
# exercised outside a real deploy, and #367 rewrites these values for the real
# melargil.pt domain); it just proves the two copies still agree. Run by
# `task repo:deploy-urls`, which `task repo:lint` -> `task ci` runs in CI.
#
# Exit codes: 0 = the copies agree, 1 = drift (or the files stopped being parseable).
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
workflow="${repo_root}/.github/workflows/release-deploy.yml"
env_dir="${repo_root}/infra/helm/beekeepingit/environments"

fail=0
note() { printf '› [deploy-urls] %s\n' "$1"; }
err() {
  printf '✗ [deploy-urls] %s\n' "$1" >&2
  fail=1
}

for f in "$workflow" "$env_dir"; do
  [ -e "$f" ] || {
    err "missing $f — this check needs both copies to compare"
    exit 1
  }
done

command -v yq >/dev/null 2>&1 || {
  echo "✗ [deploy-urls] yq not found (pinned in mise.toml; run 'mise install')" >&2
  exit 1
}

# --- copy 1: the workflow's dart-defines -------------------------------------
#
# Pull the `run:` script of publish-client's build step out of the workflow with yq
# (so YAML block-scalar folding/quoting is handled properly), then read the two
# DART_DEFINES assignments out of that shell snippet. The snippet is a plain
# `if [ "$TARGET" = "staging" ]; then ... else ... fi`, so awk tracks which branch
# each assignment sits in rather than assuming an order.
run_script="$(yq -r '
  .jobs.publish-client.steps[]
  | select(.run != null and (.run | contains("--dart-define=")))
  | .run
' "$workflow")"

[ -n "$run_script" ] || {
  err "no --dart-define step found in ${workflow#"$repo_root"/} (publish-client restructured?)"
  exit 1
}

# --- copy 1b: the admin app's per-environment VITE_* build args ----------------
#
# The React admin app (#449) is baked the same way the PWA is, but with Vite
# VITE_* build args instead of Dart defines. publish-admin's build step exports
# them inside the same `if TARGET = staging … else … fi`, so read them per branch.
# The admin app is served from its own host but its OIDC issuer / API base / IdP
# account URL point at the SAME auth/app hosts the PWA uses, so they must agree
# with the same overlay values — this catches a one-sided admin URL edit.
admin_run_script="$(yq -r '
  .jobs.publish-admin.steps[]
  | select(.run != null and (.run | contains("VITE_OIDC_ISSUER")))
  | .run
' "$workflow")"

[ -n "$admin_run_script" ] || {
  err "no VITE_* build step found in ${workflow#"$repo_root"/} (publish-admin restructured?)"
  exit 1
}

# Emits `<env>\t<space-joined VITE_* assignments>` lines (one per environment).
admin_defines_by_env="$(printf '%s\n' "$admin_run_script" | awk '
  /^[[:space:]]*if[[:space:]].*TARGET.*=.*"staging"/ { branch = "staging"; next }
  /^[[:space:]]*else[[:space:]]*$/                   { if (branch == "staging") branch = "prod"; next }
  /^[[:space:]]*fi[[:space:]]*$/ {
    if (sbuf != "") print "staging\t" sbuf
    if (pbuf != "") print "prod\t" pbuf
    branch = ""; next
  }
  /^[[:space:]]*export[[:space:]]+VITE_/ {
    if (branch == "") next
    line = $0
    sub(/^[[:space:]]*export[[:space:]]+/, "", line)
    if (branch == "staging") sbuf = (sbuf == "" ? line : sbuf " " line)
    else if (branch == "prod") pbuf = (pbuf == "" ? line : pbuf " " line)
  }
')"

[ -n "$admin_defines_by_env" ] || {
  err "could not read the VITE_* branches out of publish-admin's build step"
  exit 1
}

# Value of a single VITE_* export inside one environment's assignment string.
# Values are URLs (no spaces), so a space-split isolates each `KEY="value"`.
vite_arg() { # <assignments-string> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s|^$2=\"\\{0,1\\}\\([^\"]*\\)\"\\{0,1\\}\$|\\1|p" | head -n 1
}

# Look up one environment's admin VITE_* assignment blob.
admin_defines_for() { # <env>
  printf '%s\n' "$admin_defines_by_env" | awk -F'\t' -v e="$1" '$1==e {print $2; exit}'
}

# Emits `<env>\t<DART_DEFINES value>` lines.
defines_by_env="$(printf '%s\n' "$run_script" | awk '
  /^[[:space:]]*if[[:space:]].*TARGET.*=.*"staging"/ { branch = "staging"; next }
  /^[[:space:]]*else[[:space:]]*$/                   { if (branch == "staging") branch = "prod"; next }
  /^[[:space:]]*fi[[:space:]]*$/                     { branch = ""; next }
  /^[[:space:]]*DART_DEFINES=/ {
    if (branch == "") next
    line = $0
    sub(/^[[:space:]]*DART_DEFINES=/, "", line)
    gsub(/^"|"$/, "", line)
    print branch "\t" line
  }
')"

[ -n "$defines_by_env" ] || {
  err "could not read the DART_DEFINES branches out of publish-client's build step"
  exit 1
}

# Value of a single --dart-define key inside one environment's flag string.
dart_define() { # <defines-string> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s|^--dart-define=$2=||p" | head -n 1
}

# --- normalization ------------------------------------------------------------
# Legitimate differences that are NOT drift: trailing slashes, surrounding quotes,
# host casing. Normalize them away before comparing so the check only fires on a
# genuine hostname/URL mismatch.
norm_url() { printf '%s' "$1" | sed -e 's|^"\(.*\)"$|\1|' -e 's|/*$||' | tr '[:upper:]' '[:lower:]'; }
# Authority (host[:port]) of a URL. Port is deliberately kept: a stray port IS drift.
url_host() { printf '%s' "$(norm_url "$1")" | sed -e 's|^[a-z][a-z0-9+.-]*://||' -e 's|[/?#].*$||'; }

expect() { # <env> <what> <actual> <expected>
  if [ "$(norm_url "$3")" = "$(norm_url "$4")" ]; then
    note "$1: $2 ✓"
  else
    err "$1: $2 — workflow/derived value '$3' != overlay value '$4'"
  fi
}

# --- compare, per environment -------------------------------------------------
checked=0
while IFS="$(printf '\t')" read -r env defines; do
  [ -n "$env" ] || continue
  overlay="${env_dir}/${env}.yaml"
  [ -f "$overlay" ] || {
    err "$env: workflow builds this environment but ${overlay#"$repo_root"/} does not exist"
    continue
  }

  issuer="$(dart_define "$defines" OIDC_ISSUER)"
  gateway="$(dart_define "$defines" GATEWAY_BASE_URL)"
  account="$(dart_define "$defines" OIDC_ACCOUNT_URL)"
  powersync="$(dart_define "$defines" POWERSYNC_URL)"
  for pair in "OIDC_ISSUER=$issuer" "GATEWAY_BASE_URL=$gateway" \
    "OIDC_ACCOUNT_URL=$account" "POWERSYNC_URL=$powersync"; do
    [ -n "${pair#*=}" ] || err "$env: workflow has no --dart-define=${pair%%=*}"
  done

  # yq resolves quoting and strips the overlays' inline `# TODO:` comments, so the
  # values below are the real scalars — no grep fragility. `null` = key absent.
  app_origin="$(yq -r '.global.appOrigin // "null"' "$overlay")"
  app_host="$(yq -r '.gateway.appHost // "null"' "$overlay")"
  auth_host="$(yq -r '.gateway.authHost // "null"' "$overlay")"
  issuer_url="$(yq -r '.services.oidc.issuerUrl // "null"' "$overlay")"
  admin_origin="$(yq -r '.global.adminOrigin // "null"' "$overlay")"
  admin_host="$(yq -r '.gateway.adminHost // "null"' "$overlay")"

  # An overlay may legitimately carry no PWA-facing URLs at all (e.g. a local-only
  # environment the release workflow never builds) — that is not drift, skip it.
  if [ "$app_origin" = "null" ] && [ "$app_host" = "null" ] && [ "$auth_host" = "null" ]; then
    note "$env: overlay declares no PWA URLs — skipped"
    continue
  fi

  checked=$((checked + 1))
  note "$env: comparing release-deploy.yml dart-defines against ${overlay#"$repo_root"/}"

  expect "$env" "GATEWAY_BASE_URL vs global.appOrigin" "$gateway" "$app_origin"
  expect "$env" "GATEWAY_BASE_URL host vs gateway.appHost" "$(url_host "$gateway")" "$app_host"
  expect "$env" "OIDC_ISSUER vs services.oidc.issuerUrl" "$issuer" "$issuer_url"
  expect "$env" "OIDC_ISSUER host vs gateway.authHost" "$(url_host "$issuer")" "$auth_host"
  expect "$env" "OIDC_ACCOUNT_URL host vs gateway.authHost" "$(url_host "$account")" "$auth_host"
  # POWERSYNC_URL is the gateway origin + the /sync-stream/ route, so its authority
  # must match appHost too (a same-origin path difference is not drift).
  expect "$env" "POWERSYNC_URL host vs gateway.appHost" "$(url_host "$powersync")" "$app_host"

  # --- admin host vs admin origin, WITHIN the overlay (#556) -------------------
  # `global.adminOrigin` is what the services allowlist for CORS and what
  # Authentik registers as the admin client's redirect URI; `gateway.adminHost`
  # is the Ingress host (and TLS SAN entry) that actually serves it. Nothing
  # derives one from the other, so a one-sided edit ships an origin no host
  # answers on — the same class of drift that put `admin.beekeepingit.local` in
  # staging's public certificate. The chart's `gateway.assertPublicHostnames`
  # guard catches the DEPLOYED copy at render time; this catches the in-repo copy
  # for free, before a push. (This script cannot see the gitops repo — that stays
  # the guard's job.)
  if [ "$admin_origin" = "null" ] && [ "$admin_host" = "null" ]; then
    note "$env: overlay declares no admin URLs — skipped"
  else
    expect "$env" "global.adminOrigin host vs gateway.adminHost" "$(url_host "$admin_origin")" "$admin_host"
  fi

  # --- admin app (#449): its VITE_* URLs point at the same auth/app hosts ------
  # publish-admin bakes these into the admin image per environment; they must
  # agree with the overlay the image is served alongside, exactly like the PWA.
  admin_defines="$(admin_defines_for "$env")"
  if [ -n "$admin_defines" ]; then
    admin_issuer="$(vite_arg "$admin_defines" VITE_OIDC_ISSUER)"
    admin_api="$(vite_arg "$admin_defines" VITE_API_BASE_URL)"
    admin_account="$(vite_arg "$admin_defines" VITE_ACCOUNT_URL)"
    for pair in "VITE_OIDC_ISSUER=$admin_issuer" "VITE_API_BASE_URL=$admin_api" \
      "VITE_ACCOUNT_URL=$admin_account"; do
      [ -n "${pair#*=}" ] || err "$env: publish-admin has no ${pair%%=*}"
    done
    expect "$env" "VITE_OIDC_ISSUER vs services.oidc.issuerUrl" "$admin_issuer" "$issuer_url"
    expect "$env" "VITE_OIDC_ISSUER host vs gateway.authHost" "$(url_host "$admin_issuer")" "$auth_host"
    expect "$env" "VITE_API_BASE_URL host vs gateway.appHost" "$(url_host "$admin_api")" "$app_host"
    expect "$env" "VITE_ACCOUNT_URL host vs gateway.authHost" "$(url_host "$admin_account")" "$auth_host"
  else
    err "$env: publish-client builds this environment but publish-admin has no VITE_* for it"
  fi
done <<EOF
$defines_by_env
EOF

if [ "$checked" -eq 0 ]; then
  err "no environment was actually compared — the check would pass vacuously"
fi

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'MSG'

The PWA URLs baked into the image by .github/workflows/release-deploy.yml
(publish-client's --dart-define flags) no longer agree with the cluster config in
infra/helm/beekeepingit/environments/<env>.yaml. These two copies are maintained by
hand (#369, D-27) — update BOTH, then re-run `task repo:deploy-urls`.
MSG
  exit 1
fi

note "release-deploy.yml and the helm environment overlays agree ($checked environment(s))"
