#!/usr/bin/env bash
# Single-command bring-up for the whole local dev environment (#22,
# NFR-ARC-2/NFR-ARC-3): the k3d cluster + CNPG operator (up.sh), the Flux
# controllers (a previously-manual prerequisite, see the beekeepingit-gitops
# repo's README — made idempotent here so this script is genuinely self-contained from an
# empty cluster), the beekeepingit umbrella release (Postgres+PostGIS,
# Authentik config/Postgres creds + blueprint, MinIO creds, gateway, PowerSync),
# the standalone Authentik/MinIO Flux HelmReleases (applied directly, not via the
# `main`-tracking GitOps bootstrap — see the note below), and a smoke test.
#
# Deliberately does NOT bootstrap GitOps (apply the beekeepingit-gitops repo's
# `clusters/dev/`, the one-time wiring that makes Flux auto-sync from `main`):
# that would deploy the umbrella chart from `main`, ignoring whatever's
# checked out locally — the opposite of what a pre-merge dev/test loop needs.
# See the beekeepingit-gitops README for the post-merge bootstrap step. Also
# skips the observability stack (#87) — it's not one of #22's components and its
# HelmRelease depends on that same bootstrap `GitRepository`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
chart_dir="$repo_root/infra/helm/beekeepingit"
namespace="beekeepingit-dev"

for bin in k3d kubectl helm flux flock git; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# `kubectl wait` errors immediately with "no matching resources found" if zero
# pods currently match its selector — it only polls a matched pod's condition,
# not whether one exists yet. Since these selectors target pods a Deployment/
# StatefulSet/Flux HelmRelease creates asynchronously (a moment after the
# resource that owns them is applied), wait for at least one match to exist
# first, then wait for it to be ready. Bounded by the same timeout as the
# subsequent `wait` (in 2s steps) so a wrong/stale selector fails loudly
# instead of hanging forever.
wait_for_pod() {
  local selector="$1" timeout="$2" elapsed=0 timeout_s="${2%s}"
  until kubectl -n "$namespace" get pod -l "$selector" --no-headers 2>/dev/null | grep -q .; do
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$timeout_s" ]; then
      echo "error: no pod matching '$selector' appeared within ${timeout}" >&2
      exit 1
    fi
    sleep 2
  done
  kubectl -n "$namespace" wait --for=condition=ready pod -l "$selector" --timeout="$timeout"
}

# Keep this WSL distro's process table non-empty for the whole dev session.
# Observed live (2026-07-17): the k3s server container gets SIGTERM'd and
# gracefully drains within ~1-2 minutes of no attached WSL process, even with
# `vmIdleTimeout=-1` in .wslconfig (windows-host-setup.ps1) — so a session
# with gaps between commands (exactly what driving this from outside WSL looks
# like) can silently tear the cluster down mid-session. A trivial detached
# heartbeat sidesteps whichever exact WSL/idle mechanism is responsible.
# Idempotent (checked via the recorded PID, not just file existence) so
# re-running dev-up.sh never stacks up duplicate heartbeats; stopped by
# dev-down.sh. This can't prevent the HOST machine itself from sleeping —
# see infra/README.md's note on that separate, unscriptable cause.
keepalive_pidfile="/tmp/beekeeping-keepalive.pid"
if [ -f "$keepalive_pidfile" ] && kill -0 "$(cat "$keepalive_pidfile")" 2>/dev/null; then
  echo "keep-alive heartbeat already running (pid $(cat "$keepalive_pidfile"))"
else
  (while true; do sleep 20; done) &
  disown
  echo $! > "$keepalive_pidfile"
  echo "started keep-alive heartbeat (pid $(cat "$keepalive_pidfile")) — stopped by dev-down.sh"
fi

"$script_dir/up.sh"

echo
echo "installing/upgrading the Flux controllers (idempotent)"
# Base controllers only — Flux is read-only (D-27/ADR-0018 dropped image-automation).
flux install
flux check

echo
echo "fetching umbrella chart dependencies"
helm dependency build "$chart_dir"

echo
echo "installing/upgrading the beekeepingit umbrella release"
# Deliberately no `--wait` here: PowerSync can't pass its readiness probe until
# the postgres subchart's schema-grants Job (a post-install hook, since the
# `powersync` role doesn't exist yet at helm-install time — see that chart's
# templates/schema-grants-job.yaml) has granted it access to `powersync_storage`.
# Helm only runs post-install hooks *after* `--wait` is satisfied for the main
# release resources, so waiting here would deadlock: PowerSync waiting on a
# hook that waits on PowerSync. Readiness is instead waited on explicitly below,
# per component, after the hook has had a chance to run.
"$script_dir/with-lock.sh" helm upgrade --install beekeepingit "$chart_dir" \
  -f "$chart_dir/environments/dev.yaml" \
  --namespace "$namespace" --create-namespace

echo
echo "waiting for postgres"
wait_for_pod cnpg.io/cluster=beekeepingit-postgres 180s

echo
echo "applying the Authentik/MinIO Flux HelmReleases directly (local-only, not GitOps-synced)"
# These manifests live in the beekeepingit-gitops repo now (D-27/ADR-0018), not
# this one — resolve a checkout (shallow clone, or a BEEKEEPINGIT_GITOPS_DIR
# override for offline use). See gitops-dir.sh.
gitops_dir="$("$script_dir/gitops-dir.sh")"
# Both files' `dependsOn: [beekeepingit]` targets the *HelmRelease object*
# named "beekeepingit" that only exists once the cluster is GitOps-bootstrapped
# (the gitops repo's clusters/dev/) — which this script deliberately skips (see
# the note above). Stripped here for this direct-apply path only (committed files
# are untouched): the umbrella release install above already guarantees the
# credential Secret/ConfigMap these reference exist (created synchronously as
# part of applying the release's resources, independent of `--wait`), which is
# all `dependsOn` was ensuring in the first place. Applied one file at a time
# (not piped together) since neither file ends with its own trailing `---`, so
# concatenating them loses the document boundary between the two.
for f in authentik-helmrelease.yaml minio-helmrelease.yaml; do
  sed '/^  dependsOn:$/,+1d' "$gitops_dir/apps/dev/$f" \
    | "$script_dir/with-lock.sh" kubectl apply -f -
done

echo
echo "waiting for the PowerSync rollout"
kubectl -n "$namespace" rollout status deployment/beekeepingit-powersync --timeout=180s

echo
echo "waiting for Authentik (bundled-Postgres init + DB migrations + blueprint apply"
echo "can take a few minutes on a cold pull) and MinIO"
# Authentik's server Deployment is created by its Flux HelmRelease a moment after
# the HelmRelease is applied; wait for the rollout to complete (the server pod only
# goes ready once Postgres is up, migrations have run, and it can serve). A longer
# timeout than the previous IdP's wait — Authentik + its own Postgres is heavier to
# boot (ADR-0016). MinIO's vendored chart predates the app.kubernetes.io/* label
# convention — it only sets the legacy app=minio,release=<release-name> labels.
wait_for_pod app.kubernetes.io/instance=authentik 420s
kubectl -n "$namespace" rollout status deployment/authentik-server --timeout=420s
wait_for_pod app=minio,release=minio 180s

echo
echo "waiting for the Authentik blueprint (OIDC discovery answers), resetting backoffs"
# The server being Ready is NOT enough for the domain services: the WORKER
# applies the blueprint (provider/application/seed user) asynchronously after
# boot, and until it lands, OIDC discovery 404s and every Go service
# crash-restarts with a growing backoff (up to 5 min) — ported from the same
# fix in .github/workflows/helm-e2e.yml (#215), which hit this exact race in
# CI; observed live in this repo's own dev cluster too (identity/organizations/
# apiaries/activities/sync all CrashLoopBackOff on a cold multi-service boot).
# Wait for the worker rollout (it does the apply), poll discovery until it
# 200s, then restart every app once to clear the accumulated CrashLoopBackOff
# — otherwise the readiness wait below races pod backoff timers, not real
# readiness. Discovery is polled by exec-ing INTO the authentik-server pod and
# curling its own localhost — exec runs over the kube API (not pod
# networking), immune to the NetworkPolicy default-deny (#89) a runner/host
# port-forward would hit. Re-resolve the pod each iteration: authentik-server
# can restart mid-poll on a cold DB (migrations, startup-probe cycling), and a
# name captured once goes stale.
kubectl -n "$namespace" rollout status deployment/authentik-worker --timeout=600s
for i in $(seq 1 90); do
  pod=$(kubectl -n "$namespace" get pod \
    -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=server \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$pod" ] && kubectl -n "$namespace" exec "$pod" -- \
       curl -sf http://localhost:9000/application/o/beekeepingit/.well-known/openid-configuration >/dev/null 2>&1; then
    echo "discovery answered after ~$((i * 10))s"
    break
  fi
  if [ "$i" = "90" ]; then
    echo "error: blueprint never applied — discovery still 404 after 900s" >&2
    exit 1
  fi
  sleep 10
done
kubectl -n "$namespace" rollout restart deployment -l app.kubernetes.io/part-of=beekeepingit

echo
echo "waiting for domain-service deployments (clean boot after the reset above)"
kubectl -n "$namespace" wait --for=condition=available deployment \
  -l app.kubernetes.io/part-of=beekeepingit --timeout=600s

echo
echo "running helm test (PostGIS smoke query)"
helm test beekeepingit --namespace "$namespace"

echo
echo "waiting for the gateway to serve the PWA + OIDC discovery"
# The domain-service wait above asserts the pods are Available, but Traefik's
# route to the PWA can still answer 502 for a short window after that
# (endpoints/first-request not warm). Warm both dev hosts (resolving to
# loopback, matching windows-host-setup.ps1's /etc/hosts entries) before
# declaring the environment browser-ready — mirrors helm-e2e.yml's own `warm`
# gate ahead of its Playwright run. Accept any response under 500 as warm (even
# a redirect/401) — a 5xx/000 (connection refused) is not.
warm() {
  local name="$1" host="$2" path="$3" code=000
  for _ in $(seq 1 60); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' \
      --resolve "$host:8443:127.0.0.1" "https://$host:8443$path" || echo 000)
    if [ "$code" != "000" ] && [ "$code" -lt 500 ]; then
      echo "$name warm (HTTP $code)"
      return 0
    fi
    sleep 5
  done
  echo "error: $name never warmed (last HTTP $code)" >&2
  return 1
}
warm "PWA" app.beekeepingit.local /
warm "OIDC discovery" auth.beekeepingit.local \
  /application/o/beekeepingit/.well-known/openid-configuration

cat <<EOF

Local dev environment ready — genuinely browser-ready (the gateway is warm on
both dev hosts, not just "pods Available"). Open:

  https://app.beekeepingit.local:8443

(first visit: a one-time click-through past the self-signed dev cert — see
infra/README.md; trusted-cert issuance is EPIC-14 scope). Seeded dev login:

  test.beekeeper@beekeepingit.local / dev-password123

First-time-per-machine setup (hosts file + WSL idle-timeout) is
infra/cluster/windows-host-setup.ps1 — see infra/README.md#quickstart. Further
smoke checks: infra/README.md#verify-the-environment.
EOF
