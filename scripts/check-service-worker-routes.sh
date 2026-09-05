#!/usr/bin/env bash
# Verify the app-shell service worker's SERVER_ROUTED_PREFIXES still covers every
# path the gateway routes on the APP host to a backend service (#683, FR-OF-1,
# FR-PL-1, D-10).
#
# WHY THIS CHECK EXISTS
# ---------------------
# client/web/service_worker.js answers a top-level navigation from the cached
# `/index.html`, exactly as nginx's SPA fallback would — but the worker's scope is
# the whole ORIGIN, and the gateway peels some of that origin's paths off to Go
# services and to PowerSync before nginx ever sees them. So the worker carries an
# exclusion list:
#
#   const SERVER_ROUTED_PREFIXES = ["/v1/", "/sync-stream"];
#
# which is a hand-maintained mirror of the gateway chart's `routes` +
# `powersyncRoute` (ADR-0026, Decision item 4). Add a gateway route on the app host
# that is not under one of those prefixes and a navigation to it is answered from the
# cache with the app shell instead of reaching the server — SILENTLY: `helm lint` is
# green, the pod is Ready, and every API call still works, because API calls are
# `fetch`, which never reaches the worker's navigation branch. Only a browser
# navigation — a downloaded export, a presigned-object redirect, a `.well-known`
# endpoint, someone pasting the URL — sees the wrong thing, and only on a client that
# has the worker installed.
#
# Same shape, same answer as scripts/check-deploy-url-drift.sh (#369) and
# scripts/check-app-shell-precache-wired.sh (#619): two copies with no shared source,
# so a script proves they still agree.
#
# WHAT IT DELIBERATELY IGNORES
# ----------------------------
# `authRoutes` and `adminRoutes`. Those are the auth and admin HOSTS — different
# origins, so this worker's scope never covers them and a prefix for them would be
# noise, not safety. Only `routes` (the app host) and `powersyncRoute` (also the app
# host) are in scope, and within `routes`, only the entries that do NOT go to the PWA
# container: `/` → pwa is what nginx serves, i.e. exactly what the cached shell is a
# correct answer for.
#
# WHAT IT CANNOT SEE
# ------------------
# The values that actually run. The deployed release is configured by the gitops
# repo's HelmRelease (beekeepingit-gitops → `apps/<env>/`), not by anything in this
# repo — the same blind spot check-deploy-url-drift.sh records. A `gateway.routes`
# override there is a third copy no in-repo gate can reach; the chart's own
# `assertPublicHostnames` guard is the model for catching that class at render time.
# The failsafe near the bottom covers the in-repo overlays only.
#
# Parsed with awk rather than yq on purpose. yq is pinned in mise.toml and
# check-deploy-url-drift.sh genuinely needs it (it reads a workflow's block scalars,
# which nothing else can do), but the two keys read here are a flat list of
# `{ path, service, port }` mappings, and keeping this gate dependency-free means it
# also runs in a bare shell — a pre-push hook, a container without mise. Within
# `task repo:lint` that buys nothing (deploy-urls runs two steps earlier and hard-
# requires yq); outside it, it is the difference between running and not.
#
# Runs from `task repo:lint` (CI + local).
#
# Exit codes: 0 = the worker covers every app-host service route, 1 = drift, an
# unparseable file, or a chart this check no longer fully sees.
set -euo pipefail

# No `git rev-parse`: this must work in a bare checkout, and a failing `git` inside a
# command substitution would leave `cd ""` — a silent no-op that makes every relative
# path below resolve against the caller's directory. Same idiom as
# check-deploy-url-drift.sh.
repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

readonly CHART='infra/helm/beekeepingit/charts/gateway/values.yaml'
readonly WORKER='client/web/service_worker.js'
readonly PWA_SERVICE_TEMPLATE='infra/helm/beekeepingit/charts/pwa/templates/service.yaml'
# Every other in-repo values file that could override `gateway.routes` /
# `gateway.powersyncRoute`. None does today; the failsafe near the bottom notices if
# one starts to.
readonly OVERRIDE_FILES=(
  'infra/helm/beekeepingit/values.yaml'
  'infra/helm/beekeepingit/environments/'*.yaml
)

# Prefixes the worker may exclude even though the gateway chart declares no matching
# route — the escape hatch for the reverse-direction check below. `routes` +
# `powersyncRoute` are a SUBSET of the app-host paths that bypass nginx: cert-manager's
# ACME HTTP-01 solver, for instance, creates its own Ingress for
# `/.well-known/acme-challenge/*` when `gateway.certManager.enabled` is on, and it
# appears in no values file. Nothing needs an entry today (nothing navigates to the
# solver), but a correct exclusion must have somewhere to live other than "delete it".
# One prefix per line; comment each with WHY the chart cannot declare it.
readonly NOT_CHART_ROUTED=''

status=0
note() { printf '› [sw-routes] %s\n' "$1"; }
err() {
  printf '✗ [sw-routes] %s\n' "$1" >&2
  shift
  for extra in "$@"; do printf '  %s\n' "$extra" >&2; done
  status=1
}
fatal() {
  err "$@"
  exit 1
}

for file in "$CHART" "$WORKER"; do
  [ -f "$file" ] || fatal "missing $file — this check needs both copies to compare"
done

# --- copy 1: the gateway chart's app-host routes ------------------------------
#
# Emits `<path>\t<service>` for each entry of a TOP-LEVEL key holding either a
# sequence of mappings (`routes`) or a single mapping (`powersyncRoute`), in flow
# style (`- { path: /v1/x, service: x, port: 8080 }`) or block style alike. Anchored
# at column 0, so `adminRoutes:`/`authRoutes:` — the other HOSTS — can never be
# mistaken for `routes:`. awk exits 3 when the key is absent, which the callers turn
# into a hard failure rather than into "no routes".
yaml_entries() { # <file> <top-level key>
  awk -v key="$2" '
    function flush() { if (path != "") { print path "\t" service }; path = ""; service = "" }

    # Drop trailing comments first, then comment-only and blank lines, so a `#`
    # explaining a route can never be read as part of one.
    { sub(/[ \t]+#.*$/, "") }
    /^[ \t]*(#|$)/ { next }

    # A column-0 key ends whatever block we were in, and may start ours.
    /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      if (inblock) { flush(); inblock = 0 }
      if ($0 ~ "^" key ":") { inblock = 1; found = 1 }
      next
    }
    !inblock { next }

    # A `-` starts the next sequence entry, so the previous one is complete.
    /^[ \t]*-/ { flush() }
    {
      # The `[^A-Za-z_-]` guard keeps a key like `subpath:` from matching `path:`.
      if (match($0, /(^|[^A-Za-z_-])path:[ \t]*[^,} \t]+/)) {
        value = substr($0, RSTART, RLENGTH)
        sub(/.*path:[ \t]*/, "", value)
        gsub(/["'"'"']/, "", value)
        path = value
      }
      if (match($0, /(^|[^A-Za-z_-])service:[ \t]*[^,} \t]+/)) {
        value = substr($0, RSTART, RLENGTH)
        sub(/.*service:[ \t]*/, "", value)
        gsub(/["'"'"']/, "", value)
        service = value
      }
    }
    END { if (inblock) flush(); if (!found) exit 3 }
  ' "$1"
}

app_routes="$(yaml_entries "$CHART" routes)" || fatal \
  "no top-level \`routes:\` in $CHART — the gateway chart was restructured;" \
  "teach this check where the app-host routes moved to."
powersync_route="$(yaml_entries "$CHART" powersyncRoute)" || fatal \
  "no top-level \`powersyncRoute:\` in $CHART — the gateway chart was restructured;" \
  "teach this check where the sync-stream route moved to."

[ -n "$app_routes" ] || fatal "\`routes:\` in $CHART parsed to nothing — the entry shape changed."

# The Service behind the app host's `/` catch-all is the PWA container: nginx's own
# `try_files … /index.html` answers everything under it, so the cached shell IS the
# right answer there and those routes need no exclusion. Derived rather than
# hardcoded to "pwa", so renaming the Service doesn't turn every PWA route into a
# false failure.
pwa_service="$(printf '%s\n' "$app_routes" | awk -F'\t' '$1 == "/" && found == "" { found = $2 } END { print found }')"

# …but "derived" must not become "whatever `/` happens to point at". If `path: /`
# were ever repointed at a Go service, every route to that service would be skipped
# as "nginx serves it" and this gate would pass while the worker shadowed the whole
# origin. So the derived name is cross-checked against the Service the pwa subchart
# actually declares. Skipped (with a note) if that name ever becomes templated —
# comparing against a `{{ … }}` literal would be a false failure.
#
# No `| head -n 1` here: `head` would close the pipe and SIGPIPE the awk upstream,
# which under `set -o pipefail` is exit 141 — i.e. this assignment would abort the
# whole script (the hazard check-app-shell-precache-wired.sh documents). awk reads
# the file directly, so its own `exit` is the safe way to stop at the first match.
declared_pwa_service=''
if [ -f "$PWA_SERVICE_TEMPLATE" ]; then
  declared_pwa_service="$(awk '
    /^kind:[ \t]*Service/ { in_svc = 1 }
    in_svc && /^[ \t]+name:[ \t]*[^ \t]/ {
      value = $0; sub(/^[ \t]+name:[ \t]*/, "", value); print value; exit
    }' "$PWA_SERVICE_TEMPLATE")"
fi
is_templated() { case "$1" in *'{{'*) return 0 ;; esac; return 1; }

if [ -n "$pwa_service" ]; then
  if [ -z "$declared_pwa_service" ] || is_templated "$declared_pwa_service"; then
    note "pwa Service name is templated or unreadable — trusting the chart's '/' route"
  elif [ "$pwa_service" != "$declared_pwa_service" ]; then
    fatal \
      "the app host's '/' catch-all now points at Service '$pwa_service', but the pwa" \
      "subchart declares '$declared_pwa_service'. If '/' no longer reaches the PWA" \
      "container, the cached app shell is the wrong answer for it and this check's" \
      "whole exemption is invalid — resolve that before trusting this gate."
  fi
  note "app host serves '/' from the '$pwa_service' Service — its routes need no exclusion"
else
  note "app host has no '/' catch-all — treating every route as server-routed"
fi

# `<path>\t<why>` for everything on the app host that must NOT be answered from cache.
server_routed="$(
  printf '%s\n' "$app_routes" | awk -F'\t' -v pwa="$pwa_service" '
    $1 == "" { next }
    pwa != "" && $2 == pwa { next }
    { print $1 "\troutes[] → " $2 }
  '
  printf '%s\n' "$powersync_route" | awk -F'\t' '$1 != "" { print $1 "\tpowersyncRoute → " $2 }'
)"

# A rename or a chart reshuffle that leaves this check with nothing to compare would
# make it silently useless — the same failure mode it exists to prevent.
[ -n "${server_routed//[[:space:]]/}" ] || fatal \
  "the chart routes NOTHING on the app host past the '/' catch-all — this check now guards nothing"

# --- copy 2: the worker's exclusion list --------------------------------------
#
# Reads the array literal itself, not a second hand-written list. Collects from the
# `const` line to the first `]`, then keeps only PATH-shaped tokens (`"/…"`).
# Both narrowings matter: without them a `//` comment anywhere in the literal
# contributes its own quoted words as phantom prefixes — and a comment containing
# `"/"` would make one prefix cover the entire origin, turning this gate green
# forever, which is exactly the silent pass it exists to prevent.
prefixes=()
prefix_count=0
while IFS= read -r prefix; do
  [ -n "$prefix" ] || continue
  # A bare `/` can only be a parse artifact or a mistake: it would exclude every
  # navigation, i.e. the worker would never serve the shell and the app would stop
  # working offline entirely.
  [ "$prefix" != "/" ] || fatal \
    "SERVER_ROUTED_PREFIXES contains a bare \"/\" — that excludes EVERY navigation," \
    "so the worker would never serve the cached shell and the app could not start" \
    "offline at all. Remove it (or fix whatever generated it)."
  prefixes+=("$prefix")
  prefix_count=$((prefix_count + 1))
done < <(awk '
  # Strip `//` comments per line before buffering, and truncate at the closing `]`,
  # so nothing a human wrote alongside the array is read as part of it.
  { sub(/\/\/.*$/, "") }
  /^const SERVER_ROUTED_PREFIXES[ \t]*=/ { collecting = 1 }
  collecting {
    line = $0
    if (line ~ /\]/) { sub(/\].*$/, "", line); print buffer line; exit }
    buffer = buffer line
  }
' "$WORKER" | grep -oE '"/[^"]*"' | tr -d '"')

[ "$prefix_count" -gt 0 ] || fatal \
  "no \`const SERVER_ROUTED_PREFIXES = [\"/…\"]\` in $WORKER." \
  "Either it was renamed (update this check) or the navigation branch lost its exclusion" \
  "list entirely, which would answer EVERY navigation from the cached app shell."
note "worker excludes: ${prefixes[*]}"

# --- compare ------------------------------------------------------------------
#
# A prefix COVERS a route when the route path starts with it — Ingress
# `pathType: Prefix` matches everything under the route path, and the worker's own
# test is `url.pathname.startsWith(prefix)`, so that is exactly the runtime question.
# `"$prefix"` is quoted inside the `case` pattern so a glob metacharacter is matched
# literally, the way `startsWith` would match it.
covered_by() { # <path>
  local path="$1" prefix
  for prefix in "${prefixes[@]}"; do
    case "$path" in "$prefix"*) return 0 ;; esac
  done
  return 1
}

checked=0
while IFS="$(printf '\t')" read -r path why; do
  [ -n "$path" ] || continue
  checked=$((checked + 1))
  if covered_by "$path"; then
    note "ok: $path ($why) is excluded from the cached shell"
  else
    err "$path ($why) is on the app host but is not served by its '/' catch-all," \
      "and no SERVER_ROUTED_PREFIXES entry covers it — a navigation there would be" \
      "answered from the cached app shell instead of reaching the server."
  fi
done <<<"$server_routed"

# The other direction: a prefix matching no route is a leftover, and it makes the
# worker skip the cached shell for a path that IS a client-side route — i.e. that
# navigation quietly stops working offline. NOT_CHART_ROUTED is the escape hatch for
# an exclusion the chart legitimately cannot declare.
for prefix in "${prefixes[@]}"; do
  if printf '%s\n' "$NOT_CHART_ROUTED" | grep -qxF -- "$prefix"; then
    note "ok: '$prefix' is a declared non-chart exclusion (see NOT_CHART_ROUTED)"
    continue
  fi
  if ! printf '%s\n' "$server_routed" |
    awk -F'\t' -v p="$prefix" 'index($1, p) == 1 { hit = 1 } END { exit !hit }'; then
    err "'$prefix' matches no app-host service route in $CHART — a stale exclusion" \
      "makes that path fall through to the network, so it stops working offline." \
      "Drop it, add the route it is meant to guard, or — if the gateway chart cannot" \
      "declare that route (a cert-manager solver Ingress, say) — list it in this" \
      "script's NOT_CHART_ROUTED with a note saying why."
  fi
done

# --- failsafe: nothing else may quietly add app-host routes -------------------
#
# The umbrella values and the per-environment overlays override `gateway.appHost` &
# friends today, never `gateway.routes`. If one starts to, this check would be reading
# an incomplete picture — so it fails and asks to be taught, rather than passing on a
# chart it no longer fully sees. Scoped to the `gateway:` block: a `routes:` key under
# any OTHER subchart (a vendored chart's own ingress, say) is none of this gate's
# business and must not fail it.
for file in "${OVERRIDE_FILES[@]}"; do
  [ -f "$file" ] || continue
  override_keys="$(awk '
    { sub(/[ \t]+#.*$/, "") }
    /^[ \t]*(#|$)/ { next }
    /^[A-Za-z_][A-Za-z0-9_-]*:/ { inblock = ($0 ~ /^gateway:/); next }
    inblock && /^[ \t]+(routes|powersyncRoute):/ { print $1 }
  ' "$file" | tr '\n' ' ')"
  [ -n "${override_keys// /}" ] || continue
  err "$file declares gateway route overrides this check does not read: $override_keys" \
    "Extend the parser to merge them before trusting this gate again."
done

if [ "$status" -ne 0 ]; then
  cat >&2 <<'MSG'

client/web/service_worker.js's SERVER_ROUTED_PREFIXES no longer matches the app-host
routes in infra/helm/beekeepingit/charts/gateway/values.yaml. These two copies are
maintained by hand (#683, ADR-0026 Decision item 4) — update BOTH, then re-run
`task repo:service-worker-routes`.
MSG
  exit 1
fi

printf '✓ [sw-routes] the app-shell worker excludes every app-host service route (%s checked)\n' "$checked"
