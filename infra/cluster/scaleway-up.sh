#!/usr/bin/env bash
# One-command bring-up for a Scaleway Kapsule cluster (D-26) — staging by
# default, prod via BK_CLUSTER_ENV=prod. Idempotent: safe to re-run against an
# already-provisioned cluster. Ends fully GitOps-bootstrapped (see below), so
# after this script Flux reconciles the environment on its own.
#
# Configuration/secrets come from the environment. For local runs put them in
# infra/cluster/.env (gitignored; loaded via env.sh — see .env.example for the
# full list). In CI (.github/workflows/cluster-ops.yml) the same variable names
# are injected from GitHub secrets/variables. GitHub secrets are write-only —
# a local run cannot read them back — hence the .env file for manual use.
#
# Prerequisites (done once by hand, not by this script):
#   - a Scaleway account with billing set up, in an EU region
#   - API credentials: either `scw init` (stores a local profile) or the
#     SCW_ACCESS_KEY / SCW_SECRET_KEY / SCW_DEFAULT_PROJECT_ID /
#     SCW_DEFAULT_ORGANIZATION_ID env vars (what CI uses — see
#     https://www.scaleway.com/en/docs/console/account/how-to/create-api-keys/)
#
# Optional dynamic DNS (D-27/Phase 5): set CF_API_TOKEN / CF_ZONE_ID /
# APP_HOST / AUTH_HOST and this script pushes Traefik's freshly-assigned
# LoadBalancer IP to Cloudflare on each bring-up. We deliberately do NOT
# reserve a static Scaleway IP (a held flexible IP bills ~EUR3/mo even while
# the cluster is torn down); dynamic DNS keeps the standing cost at zero.
# Skipped if CF_API_TOKEN is unset (then point DNS by hand from the summary
# printed at the end):
#   CF_API_TOKEN  Cloudflare token, scoped to Zone > DNS > Edit on the zone
#   CF_ZONE_ID    the zone's ID (Cloudflare dashboard -> the zone -> API section)
#   APP_HOST      e.g. beekeepingit-rc.melargil.pt
#   AUTH_HOST     e.g. auth.beekeepingit-rc.melargil.pt
# (STAGING_APP_HOST/STAGING_AUTH_HOST are accepted as legacy aliases.)
#
# Optional Authentik outbound-email relay credentials (#361, NFR-SEC-1): set
# AUTHENTIK_EMAIL_USERNAME / AUTHENTIK_EMAIL_PASSWORD and this script creates/
# updates the out-of-band `beekeepingit-authentik-email-credentials` Secret the
# authentik subchart merges into its config at render time (see that chart's
# config-secret.yaml — the cluster-state-not-git idiom; every other in-cluster
# secret is chart-generated and needs nothing from here).
#
# GitOps bootstrap: applies the beekeepingit-gitops repo's clusters/<env>/
# (Flux GitRepository/Kustomizations + the cert-manager ClusterIssuer), so
# bring-up is genuinely one command — unlike dev-up.sh, which deliberately
# SKIPS bootstrap because a pre-merge dev loop must deploy the local checkout,
# not `main`. Staging/prod have the opposite need: they should track the gitops
# repo. Set SKIP_GITOPS_BOOTSTRAP=1 to opt out (e.g. debugging an unmerged
# chart against a fresh cluster).
#
# D-26 scope guard on prod: bring-up of the prod cluster is allowed (an empty
# cluster holds no user data), but deployments stay staging-grade until DR
# (Q-DR) and GDPR export/erasure (#90) land — don't cut a bare (non-rc)
# release onto it before those close.
#
# Gotcha - a stale DNSSEC DS record at the registry silently blocks cert issuance.
# Symptom: the cluster and app come up healthy and the HTTP-01 challenge shows
# Presented=true, but the Certificate stays `pending` and `kubectl describe
# challenge` reports the cert-manager self-check failing with
# `lookup <host> on 10.32.0.10:53: server misbehaving` (10.32.0.10 = CoreDNS).
# Not a cluster fault: if the registry publishes a DS whose key tag no longer
# matches the DNSKEY Cloudflare signs with, every validating resolver (1.1.1.1,
# 8.8.8.8, and CoreDNS's upstream) SERVFAILs, so the host resolves nowhere even
# though the Cloudflare A records are correct. Diagnose: `dig <d> NS @8.8.8.8
# +short` comes back empty, but `dig <d> SOA @1.1.1.1 +cd +short` (validation
# disabled) and a query against the zone's Cloudflare NS both answer => DNSSEC
# validation, not delegation; inspect the published DS with `dig <d> DS @1.1.1.1
# +cd +short`. The fix is registrar-side only - the DS lives at the registry, and
# nothing in Cloudflare or this cluster can remove it: drop the stale DS, or
# replace it with the one shown under Cloudflare DNS > Settings > DNSSEC.
# cert-manager then issues on its next retry. Note melargil.pt's Cloudflare zone
# lives on a separate Cloudflare account, so CF_API_TOKEN must belong to it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional local config/secrets from infra/cluster/.env (see .env.example).
# shellcheck disable=SC1091 # resolved at runtime next to this script
. "$script_dir/env.sh"

env_name="${BK_CLUSTER_ENV:-staging}"
case "$env_name" in
  staging | prod) ;;
  *)
    echo "error: BK_CLUSTER_ENV must be 'staging' or 'prod' (got '$env_name')" >&2
    exit 1
    ;;
esac

cluster_name="${SCW_K8S_CLUSTER_NAME:-beekeepingit-$env_name}"
namespace="beekeepingit-$env_name"
region="${SCW_REGION:-fr-par}"
# DEV1-M (3vCPU/4GB) was the original default but proved insufficient on the
# first staging bring-up (D-26): the full stack (CNPG, Traefik, cert-manager,
# Flux's 6 controllers, Postgres, Authentik + its bundled Postgres, MinIO,
# PowerSync, PWA, 7 Go services) pushed memory *requests* alone to ~90% of
# allocatable, leaving no room for one-off Jobs (Authentik's blueprint-apply
# worker, MinIO's bucket-creation post-install hook) to even get scheduled —
# both sat Pending on "Insufficient memory" indefinitely. DEV1-L (4vCPU/8GB,
# ~€30.66/mo vs DEV1-M's ~€14.26/mo) gives real headroom instead of inching
# up; revisit down if usage stays low once the stack is stable.
node_type="${SCW_NODE_TYPE:-DEV1-L}"

app_host="${APP_HOST:-${STAGING_APP_HOST:-}}"
auth_host="${AUTH_HOST:-${STAGING_AUTH_HOST:-}}"

for bin in scw kubectl helm flux; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# Fail fast with a useful message when the Scaleway credentials are missing or
# incomplete — otherwise the first `scw` call fails mid-run with a bare
# denied/401. Without a `scw init` profile, a profile-less run needs all four.
if [ ! -f "${HOME}/.config/scw/config.yaml" ]; then
  missing=""
  for v in SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_ORGANIZATION_ID; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    echo "error: no scw profile (~/.config/scw/config.yaml) and missing:$missing" >&2
    echo "either run 'scw init' once, or set all four SCW_* variables" >&2
    echo "(locally via infra/cluster/.env — see .env.example; in CI via GitHub secrets)" >&2
    exit 1
  fi
fi

# Resolve the GitOps checkout for step 6 UP FRONT, so a missing/broken
# clusters/<env>/ fails here — before any billed Scaleway resource exists —
# rather than stranding a half-provisioned cluster on the last step.
gitops_dir=""
if [ "${SKIP_GITOPS_BOOTSTRAP:-}" != "1" ]; then
  gitops_dir="$("$script_dir/gitops-dir.sh")"
  if [ ! -d "$gitops_dir/clusters/$env_name" ]; then
    echo "error: '$gitops_dir/clusters/$env_name' does not exist — the beekeepingit-gitops repo has no $env_name bootstrap manifests (set SKIP_GITOPS_BOOTSTRAP=1 to bring the cluster up without them)" >&2
    exit 1
  fi
fi

# Same flock idiom as infra/cluster/up.sh, but note two caveats that don't
# carry over here. (1) up.sh's lock protects one shared *local* cluster from
# concurrent sessions on the *same machine* (it's a plain local lockfile).
# This remote cluster can equally be reached from any machine with credentials
# for the same Scaleway project — including the GitHub Actions runners
# cluster-ops.yml uses — so even when available this lock only protects
# against a race with another session on *this* machine — it is not
# distributed coordination. Keep this project single-maintainer-operated until
# that's addressed (e.g. locking at the Scaleway resource level, or routing
# all real changes through CI). (2) unlike up.sh's WSL2/Linux environment,
# `flock` is a util-linux tool, not bundled with Git Bash on Windows — so it's
# treated as optional here, not required.
if command -v flock >/dev/null 2>&1; then
  lockfile="/tmp/scw-k8s-${cluster_name}.lock"
  exec 200>"$lockfile"
  if ! flock -w 300 200; then
    echo "error: timed out waiting for the '$cluster_name' cluster lock — another session on this machine appears to be using it" >&2
    exit 1
  fi
else
  echo "warning: 'flock' not found — skipping the same-machine concurrency lock (harmless for single-operator use)" >&2
fi

# 1. Create (or find) the cluster.
cluster_id="$(scw k8s cluster list name="$cluster_name" region="$region" -o template='{{ .ID }}' 2>/dev/null || true)"
if [ -n "$cluster_id" ]; then
  echo "cluster '$cluster_name' already exists (id $cluster_id) in $region — reusing it"
else
  # Look up the latest supported version instead of hardcoding one:
  # Kapsule only supports the last ~3 minor releases (~12mo each per
  # https://www.scaleway.com/en/docs/kubernetes/reference-content/version-support-policy/),
  # so a pinned constant here would eventually create a cluster with a
  # rejected version. Override with SCW_K8S_VERSION if you want a specific
  # one instead (e.g. to match an existing cluster's version during upgrade
  # testing).
  k8s_version="${SCW_K8S_VERSION:-}"
  if [ -z "$k8s_version" ]; then
    k8s_version="$(scw k8s version list -o template='{{ .Name }}' | sort -V | tail -1)"
    echo "no SCW_K8S_VERSION set — using latest supported version: $k8s_version"
  fi
  echo "creating cluster '$cluster_name' in $region (version $k8s_version, node type $node_type)"
  cluster_id="$(scw k8s cluster create \
    name="$cluster_name" \
    region="$region" \
    version="$k8s_version" \
    cni=cilium \
    pools.0.name=default \
    pools.0.node-type="$node_type" \
    pools.0.size=1 \
    pools.0.autohealing=true \
    pools.0.autoscaling=false \
    -o template='{{ .ID }}')"
  echo "waiting for cluster '$cluster_name' (id $cluster_id) to become ready — this takes a few minutes"
  scw k8s cluster wait "$cluster_id" region="$region"
fi

# 2. Fetch kubeconfig. `kubeconfig install` sets it as the active context
# itself — not forcing a guessed context name here since it isn't documented
# and getting it wrong would hard-fail this script right after cluster
# creation succeeds. Confirm the active context is the right one instead.
scw k8s kubeconfig install "$cluster_id" region="$region"
echo "active kubectl context: $(kubectl config current-context)"
kubectl cluster-info

# 3. Cluster-scoped prerequisites — mirrors infra/cluster/up.sh's CNPG
# install, plus two things k3d bundled for free that Kapsule doesn't: an
# ingress controller and cert-manager (dev only ever needed a self-signed
# cert; a real public staging host needs a trusted one — see
# charts/gateway/values.yaml's certManager.* values).
echo "installing/upgrading the CloudNativePG operator"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo update cnpg >/dev/null
helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait

echo "installing/upgrading Traefik (ingress controller — k3d bundles this, Kapsule doesn't)"
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace --wait

# 3b. Dynamic DNS. Kapsule assigns Traefik's LoadBalancer a fresh IP on every
# bring-up (we don't reserve a static one — see the header), so push the current
# IP to Cloudflare here. DNS-only (proxied:false) so cert-manager's HTTP-01
# challenge can reach it; low TTL so the change propagates fast. Idempotent —
# re-running just re-points the records. Skipped unless CF_API_TOKEN is set.
if [ -n "${CF_API_TOKEN:-}" ]; then
  for bin in curl jq; do
    command -v "$bin" >/dev/null 2>&1 || {
      echo "error: '$bin' is required for the Cloudflare DNS update (CF_API_TOKEN is set)" >&2
      exit 1
    }
  done
  : "${CF_ZONE_ID:?set CF_ZONE_ID (the zone ID) when CF_API_TOKEN is set}"
  if [ -z "$app_host" ] || [ -z "$auth_host" ]; then
    echo "error: set APP_HOST and AUTH_HOST (e.g. beekeepingit-rc.melargil.pt / auth.beekeepingit-rc.melargil.pt) when CF_API_TOKEN is set" >&2
    exit 1
  fi

  echo "waiting for Traefik's LoadBalancer IP (Kapsule assigns it a moment after the Service is created)"
  lb_ip=""
  for _ in {1..60}; do
    lb_ip="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$lb_ip" ] && break
    sleep 5
  done
  if [ -z "$lb_ip" ]; then
    echo "error: Traefik LoadBalancer IP not assigned within 5 minutes" >&2
    exit 1
  fi
  echo "Traefik LoadBalancer IP: $lb_ip"

  cf_api="https://api.cloudflare.com/client/v4"
  # Authenticated curl with the token fed via a header FILE (`-H @path`, a
  # process substitution of the printf *builtin* — no extra process, nothing
  # on any argv), not `-H "Authorization: ..."`: a plain -H would expose the
  # token to `ps`/`/proc/*/cmdline` on a shared machine for the call's duration.
  cf_curl() {
    curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN") "$@"
  }
  # Create the A record if absent, else PATCH its content to the current IP.
  cf_upsert_a() {
    local fqdn="$1" ip="$2" rec_id
    rec_id="$(cf_curl "$cf_api/zones/$CF_ZONE_ID/dns_records?type=A&name=$fqdn" \
      | jq -r '.result[0].id // empty')"
    if [ -n "$rec_id" ]; then
      cf_curl -X PATCH -H "Content-Type: application/json" \
        "$cf_api/zones/$CF_ZONE_ID/dns_records/$rec_id" \
        --data "$(jq -nc --arg ip "$ip" '{content: $ip}')" >/dev/null
      echo "cloudflare: A $fqdn -> $ip (updated)"
    else
      cf_curl -X POST -H "Content-Type: application/json" \
        "$cf_api/zones/$CF_ZONE_ID/dns_records" \
        --data "$(jq -nc --arg n "$fqdn" --arg ip "$ip" \
          '{type: "A", name: $n, content: $ip, ttl: 120, proxied: false}')" >/dev/null
      echo "cloudflare: A $fqdn -> $ip (created)"
    fi
  }
  cf_upsert_a "$app_host" "$lb_ip"
  cf_upsert_a "$auth_host" "$lb_ip"
else
  echo "CF_API_TOKEN not set — skipping the Cloudflare DNS update (point DNS by hand; see the summary below)"
fi

echo "installing/upgrading cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --wait \
  --set crds.enabled=true

# 4. Flux controllers (same as the beekeepingit-gitops README's dev prerequisite
# — imperative, not GitOps-managed, per ADR-0009). Base controllers only: Flux is
# read-only (D-27/ADR-0018 dropped image-automation).
echo "installing Flux controllers"
flux install
flux check

# 5. Out-of-band Authentik email-relay credentials (#361, NFR-SEC-1) — the ONE
# in-cluster secret the chart can't generate (it's an external relay's
# credentials; everything else is lookup+randAlphaNum-generated in-cluster, see
# the chart's secret templates). Idempotent apply so a rotated password in the
# environment lands on re-run; the namespace is created here since Flux applies
# the release into it asynchronously later. Values never touch disk, logs, or
# any argv: `--from-file` + process substitution of the printf *builtin* keeps
# them off `ps`/`/proc/*/cmdline` (a `--from-literal` would not), and kubectl
# streams the composed Secret straight to the API.
if [ -n "${AUTHENTIK_EMAIL_USERNAME:-}" ] && [ -n "${AUTHENTIK_EMAIL_PASSWORD:-}" ]; then
  echo "creating/updating the beekeepingit-authentik-email-credentials Secret in $namespace"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$namespace" create secret generic beekeepingit-authentik-email-credentials \
    --from-file=username=<(printf %s "$AUTHENTIK_EMAIL_USERNAME") \
    --from-file=password=<(printf %s "$AUTHENTIK_EMAIL_PASSWORD") \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "AUTHENTIK_EMAIL_USERNAME/AUTHENTIK_EMAIL_PASSWORD not set — skipping the email-relay Secret (Authentik sends no authenticated outbound email until it exists)"
fi

# 6. GitOps bootstrap — apply the gitops repo's clusters/<env>/ (Flux
# GitRepository/Kustomizations + the cert-manager ClusterIssuer). Idempotent;
# from here Flux reconciles the umbrella release + Authentik/MinIO on its own,
# and deploys are promoted via release-deploy.yml's tag-bump PRs (D-27).
if [ "${SKIP_GITOPS_BOOTSTRAP:-}" != "1" ]; then
  # $gitops_dir was resolved (and clusters/<env>/ existence-checked) up front,
  # before any billed resource was created.
  echo "bootstrapping GitOps from the beekeepingit-gitops repo (clusters/$env_name/)"
  kubectl apply -f "$gitops_dir/clusters/$env_name/"
else
  echo "SKIP_GITOPS_BOOTSTRAP=1 — skipping the GitOps bootstrap (apply clusters/$env_name/ yourself when ready)"
fi

cat <<EOF

Cluster '$cluster_name' ($env_name) ready.

- DNS: if CF_API_TOKEN was set, the A records for the app/auth hosts were
  pushed to Cloudflare above. Otherwise point them at Traefik's LoadBalancer
  IP manually:

    kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

- GitOps: clusters/$env_name/ was applied (unless SKIP_GITOPS_BOOTSTRAP=1), so
  Flux now reconciles the environment from the beekeepingit-gitops repo —
  including the cert-manager ClusterIssuer. Watch it converge with:

    flux get kustomizations --watch

EOF
