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
