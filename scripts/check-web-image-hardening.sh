#!/usr/bin/env bash
# Verify the two nginx web images stay on ONE base tag and keep dropping the
# dynamic modules that drag a vulnerable package tree in behind them
# (NFR-SEC-1, #88, #716).
#
# WHY THIS CHECK EXISTS
# ---------------------
# client/Dockerfile and admin/Dockerfile do the same job — serve a static bundle
# with SPA fallback — from the same base, and there is no shared source for
# either fact. Both drifted, and both drifts are silent:
#
#  - **The tag.** admin sat on nginx:1.27-alpine (Alpine 3.21.3) while client had
#    moved to nginx:1.31-alpine (Alpine 3.24.1). Nothing failed. The admin image
#    is only rebuilt when admin/ changes, so it can carry three Alpine branches
#    of unpatched CVEs for months and CI stays green the whole time — the scan
#    that would catch it simply does not run.
#
#  - **The module tree.** The official image ships five dynamic modules and loads
#    none of them (stock /etc/nginx/nginx.conf has no `load_module` line). One of
#    them, nginx-module-image-filter, pulls
#    libgd → libxpm → libxt → libsm → **libuuid**, and libuuid is the only
#    package in the image built from the util-linux source. On 2026-09-05 that
#    one unused shared library failed every client build on 7 HIGH util-linux
#    CVEs (CVE-2026-53612 et al) — advisories against mount(8), libmount and
#    nsenter, none of which are installed at all (/bin/mount is busybox). It
#    could not be patched away (2.42.3-r0 was not in Alpine v3.24) and could not
#    be based away (nginx:1.31-alpine already IS the newest alpine tag). Deleting
#    the module that pulls it in is the fix; a `RUN apk del` is also the easiest
#    line in a Dockerfile to lose in a rebase, and losing it fails a scan minutes
#    later rather than here.
#
# WHAT IT DELIBERATELY DOES NOT DO
# --------------------------------
# It does not pin WHICH tag — bumping both images together is routine and should
# not need a script edit. It only requires that they agree, which is the property
# that was actually violated.
#
# It also does not read the built image. `/lib/apk/db/installed` is asserted
# inside the Dockerfile itself (that is the file Trivy reads), so the build fails
# on a base image that keeps libuuid alive by some other path. This gate is the
# cheap half that runs with no daemon: it proves the Dockerfile still CARRIES
# that assertion.
#
# The reverse direction matters more than the forward one: a removed module is
# only safe while no config asks for it. `js_import` in an nginx.conf plus a
# deleted nginx-module-njs is a container that dies on start, and the first place
# that shows up is a rolled deployment. So every removed module's directives are
# checked against both configs here.
#
# Runs from `task repo:lint` (CI + local).
#
# Exit codes: 0 = both images agree and stay hardened, 1 = drift, a lost
# assertion, or a config directive that needs a module the image no longer has.
set -euo pipefail

# No `git rev-parse`: this must work in a bare checkout, and a failing `git`
# inside a command substitution would leave `cd ""` — a silent no-op that makes
# every relative path below resolve against the caller's directory. Same idiom as
# check-service-worker-routes.sh.
repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

readonly DOCKERFILES=('client/Dockerfile' 'admin/Dockerfile')
readonly CONFIGS=('client/nginx.conf' 'admin/nginx.conf')

# Each entry: <apk package>|<extended regex of the directives it provides>. A
# module may be dropped only while no config uses any of its directives. Keep the
# patterns anchored on a word boundary so `js_import` matches but `assets_js_x`
# does not.
readonly MODULES=(
  'nginx-module-image-filter|\bimage_filter(_buffer|_jpeg_quality|_sharpen|_transparency|_interlace|_webp_quality)?\b'
  'nginx-module-xslt|\bxslt_(stylesheet|types|param|string_param|last_modified)\b'
  'nginx-module-geoip|\bgeoip_(country|city|org|proxy|proxy_recursive)\b'
  'nginx-module-njs|\bjs_(import|content|set|body_filter|header_filter|preload_object|path|var|periodic|fetch_.*|shared_dict_zone)\b'
  'nginx-module-acme|\bacme_(certificate|issuer|shared_zone|client)\b'
)

status=0
note() { printf '› [web-image] %s\n' "$1"; }
err() {
  printf '✗ [web-image] %s\n' "$1" >&2
  shift
  for extra in "$@"; do printf '  %s\n' "$extra" >&2; done
  status=1
}
fatal() {
  err "$@"
  exit 1
}

for file in "${DOCKERFILES[@]}" "${CONFIGS[@]}"; do
  [ -f "$file" ] || fatal "missing $file — this check needs every web image and its config"
done

# Strip `#` comments before every assertion below, so the extensive prose
# rationale in these files can never satisfy a check on its own. No directive or
# package name here contains a literal `#`.
directives_of() { sed 's/#.*//' "$1"; }

# --- 1. one base tag across both images ---------------------------------------
#
# `FROM <image>` only, anchored at column 0 — a multi-stage builder line would be
# `FROM x AS y`, which is not what these images are, and would be caught below as
# a second base rather than silently averaged in.
base_of() {
  directives_of "$1" | awk '$1 == "FROM" { print $2; found = 1 } END { exit !found }'
}

bases=()
for file in "${DOCKERFILES[@]}"; do
  # `mapfile` reports on its own read, not on the awk exit status inside the
  # process substitution, so an empty result is what "no FROM line" looks like
  # here — the count below is the one place that decides, for 0 and for 2 alike.
  mapfile -t found < <(base_of "$file")
  [ "${#found[@]}" -eq 1 ] ||
    fatal "$file has ${#found[@]} FROM lines; this check assumes exactly one single-stage base per web image" \
      "found: ${found[*]:-(none)}"
  bases+=("${found[0]}")
done

if [ "${bases[0]}" != "${bases[1]}" ]; then
  err "the two web images are on different bases — patch one and the other keeps its CVEs" \
    "${DOCKERFILES[0]}: ${bases[0]}" \
    "${DOCKERFILES[1]}: ${bases[1]}" \
    "bump both together, or split this check if they must genuinely diverge"
else
  note "both web images on ${bases[0]}"
fi

# --- 2. the unused modules stay deleted, and the libuuid assertion stays -------
for file in "${DOCKERFILES[@]}"; do
  body="$(directives_of "$file")"

  for entry in "${MODULES[@]}"; do
    pkg="${entry%%|*}"
    grep -qw -- "$pkg" <<<"$body" ||
      err "$file no longer deletes $pkg" \
        "it ships unloaded, and its dependency tree is scanned like any other package" \
        "(image-filter is the one that pulls libuuid → the util-linux advisories)"
  done

  # The Dockerfile's own proof that the delete achieved what it was for. Matched
  # loosely on the two halves that carry the meaning — the apk database path and
  # the package — so reformatting the line is free but removing it is not.
  if ! { grep -q 'apk/db/installed' <<<"$body" && grep -q 'libuuid' <<<"$body"; }; then
    err "$file dropped its libuuid assertion" \
      "the \`apk del\` is only load-bearing while something proves libuuid actually went away;" \
      "restore: && ! grep -q '^P:libuuid\$' /lib/apk/db/installed"
  fi
done

# --- 3. no config asks for a module the image no longer has -------------------
for config in "${CONFIGS[@]}"; do
  body="$(directives_of "$config")"

  for entry in "${MODULES[@]}"; do
    pkg="${entry%%|*}"
    pattern="${entry#*|}"
    if grep -qE -- "$pattern" <<<"$body"; then
      err "$config uses a directive from $pkg, which the image deletes" \
        "$(grep -nE -- "$pattern" <<<"$body" | head -3 | sed 's/^/    /')" \
        "nginx exits on an unknown directive: the pod would crash-loop on deploy, not fail here." \
        "either drop the directive, or stop deleting $pkg in both Dockerfiles and add its load_module"
    fi
  done
done

if [ "$status" -eq 0 ]; then
  note 'web images agree on their base and keep the unused module tree out'
fi
exit "$status"
