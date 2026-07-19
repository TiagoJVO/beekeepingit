#!/usr/bin/env bash
# One-command bring-up for the Scaleway Kapsule staging cluster (D-26).
# Idempotent: safe to re-run against an already-provisioned cluster.
#
# Prerequisites (Phase 0, done once by hand, not by this script):
#   - a Scaleway account with billing set up, in an EU region
#   - `scw init` already run (stores the API access/secret key + default
#     project/region — see https://www.scaleway.com/en/docs/console/account/how-to/create-api-keys/)
#
# Optional dynamic DNS (D-27/Phase 5): set the env vars below and this script
# pushes Traefik's freshly-assigned LoadBalancer IP to Cloudflare on each bring-up.
# We deliberately do NOT reserve a static Scaleway IP (a held flexible IP bills
# ~EUR3/mo even while the cluster is torn down); dynamic DNS keeps the standing
# cost at zero. Skipped if CF_API_TOKEN is unset (then point DNS by hand from the
# summary printed at the end):
#   CF_API_TOKEN      Cloudflare token, scoped to Zone > DNS > Edit on the zone
#   CF_ZONE_ID        the zone's ID (Cloudflare dashboard -> the zone -> API section)
#   STAGING_APP_HOST  e.g. beekeepingit-rc.melargil.pt
#   STAGING_AUTH_HOST e.g. auth.beekeepingit-rc.melargil.pt
set -euo pipefail

cluster_name="${SCW_K8S_CLUSTER_NAME:-beekeepingit-staging}"
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

for bin in scw kubectl helm flux; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found on PATH" >&2
    exit 1
  fi
done

# Same flock idiom as infra/cluster/up.sh, but note two caveats that don't
# carry over here. (1) up.sh's lock protects one shared *local* cluster from
# concurrent sessions on the *same machine* (it's a plain local lockfile).
# This remote cluster can equally be reached from any machine with `scw init`
# run against the same Scaleway project, so even when available this lock
# only protects against a race with another session on *this* machine — it
# is not distributed coordination. Keep this project single-maintainer-
# operated until that's addressed (e.g. locking at the Scaleway resource
# level, or routing all real changes through CI). (2) unlike up.sh's WSL2/
# Linux environment, `flock` is a util-linux tool, not bundled with Git
# Bash on Windows — so it's treated as optional here, not required.
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
  : "${STAGING_APP_HOST:?set STAGING_APP_HOST (e.g. beekeepingit-rc.melargil.pt) when CF_API_TOKEN is set}"
  : "${STAGING_AUTH_HOST:?set STAGING_AUTH_HOST (e.g. auth.beekeepingit-rc.melargil.pt) when CF_API_TOKEN is set}"

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
  # Create the A record if absent, else PATCH its content to the current IP.
  cf_upsert_a() {
    local fqdn="$1" ip="$2" rec_id
    rec_id="$(curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" \
      "$cf_api/zones/$CF_ZONE_ID/dns_records?type=A&name=$fqdn" | jq -r '.result[0].id // empty')"
    if [ -n "$rec_id" ]; then
      curl -fsS -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        "$cf_api/zones/$CF_ZONE_ID/dns_records/$rec_id" \
        --data "$(jq -nc --arg ip "$ip" '{content: $ip}')" >/dev/null
      echo "cloudflare: A $fqdn -> $ip (updated)"
    else
      curl -fsS -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        "$cf_api/zones/$CF_ZONE_ID/dns_records" \
        --data "$(jq -nc --arg n "$fqdn" --arg ip "$ip" \
          '{type: "A", name: $n, content: $ip, ttl: 120, proxied: false}')" >/dev/null
      echo "cloudflare: A $fqdn -> $ip (created)"
    fi
  }
  cf_upsert_a "$STAGING_APP_HOST" "$lb_ip"
  cf_upsert_a "$STAGING_AUTH_HOST" "$lb_ip"
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

cat <<EOF

Cluster ready. Remaining one-time setup, in order:

1. DNS: if CF_API_TOKEN was set, the A records for \$STAGING_APP_HOST /
   \$STAGING_AUTH_HOST were already pushed to Cloudflare above. Otherwise point
   them at Traefik's LoadBalancer IP manually:

     kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

2. Create the cert-manager ClusterIssuer (not templated here — it needs a
   real ACME account email; see the beekeepingit-gitops README for where this
   lands once staging is bootstrapped).

3. Bootstrap GitOps for this cluster — the Flux manifests live in the
   beekeepingit-gitops repo now (D-27/ADR-0018):

     git clone https://github.com/TiagoJVO/beekeepingit-gitops
     kubectl apply -f beekeepingit-gitops/clusters/staging/

EOF
