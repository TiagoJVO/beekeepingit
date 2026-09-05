#!/usr/bin/env bash
# Sourced (not executed) by scaleway-up.sh and scaleway-scale-up.sh (#539).
# Defines install_cluster_prereqs, which installs/upgrades every
# cluster-scoped prerequisite Kapsule doesn't bundle for free the way local
# k3d does (the CloudNativePG operator, an ingress controller, cert-manager),
# pushes Traefik's freshly assigned LoadBalancer IP to Cloudflare if
# configured, and installs Flux's controllers.
#
# All idempotent `helm upgrade --install`/`flux install` calls, so calling
# this on both a brand-new cluster (scaleway-up.sh) and a cluster whose nodes
# were just scaled back up from 0 (scaleway-scale-up.sh) is the same call —
# the pods it's (re)installing live on the nodes a scale-down just deleted,
# so coming back needs the exact same steps a first-ever bring-up does.
#
# Requires app_host/auth_host to already be set by the caller (used only for
# the optional Cloudflare DNS push), optionally admin_host (empty simply skips
# that one A record — #556), and kubectl/helm/flux already checked on PATH.

install_cluster_prereqs() {
  # OCI registry, not the classic `https://cloudnative-pg.github.io/charts` Helm
  # repo — that URL 301s to a domain whose DNS delegation is currently dead, so
  # `helm repo add` fails outright. See the longer note in up.sh; keep both call
  # sites on the same source.
  echo "installing/upgrading the CloudNativePG operator"
  helm upgrade --install cnpg-operator oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg \
    --namespace cnpg-system --create-namespace --wait

  echo "installing/upgrading Traefik (ingress controller — k3d bundles this, Kapsule doesn't)"
  helm repo add traefik https://traefik.github.io/charts >/dev/null
  helm repo update traefik >/dev/null
  helm upgrade --install traefik traefik/traefik \
    --namespace traefik --create-namespace --wait

  # Dynamic DNS. Kapsule assigns Traefik's LoadBalancer a fresh IP on every
  # (re)install (we don't reserve a static one — see scaleway-up.sh's header),
  # so push the current IP to Cloudflare here. DNS-only (proxied:false) so
  # cert-manager's HTTP-01 challenge can reach it; low TTL so the change
  # propagates fast. Idempotent — re-running just re-points the records.
  # Skipped unless CF_API_TOKEN is set.
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
      rec_id="$(cf_curl "$cf_api/zones/$CF_ZONE_ID/dns_records?type=A&name=$fqdn" |
        jq -r '.result[0].id // empty')"
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
    # The admin SPA's own origin (#449, ADR-0016) — OPTIONAL, unlike the two
    # above: `production-gate` has no ADMIN_HOST variable today, so hard-
    # requiring it would break the next prod bring-up.
    #
    # What makes leaving it soft acceptable, stated precisely: with cert-manager
    # enabled, `gateway.assertPublicHostnames` fails the chart render when
    # `gateway.adminHost` or `global.adminOrigin` is left at a `.local`/
    # `.localhost` default, and when `global.adminOrigin` is set while
    # `gateway.adminHost` is empty (#556). So the values-side mistake that
    # actually killed staging's ACME renewal is now loud at render time.
    #
    # What it does NOT cover: DNS. Nothing here verifies that a configured
    # host RESOLVES — an unset ADMIN_HOST simply means no admin A record, and
    # the chart cannot see that. Order therefore matters: create the A record
    # (this script, via ADMIN_HOST) BEFORE adding `gateway.adminHost` to the
    # deployed gitops values, or the multi-SAN order trades a rejectedIdentifier
    # failure for a failed HTTP-01 challenge — and one failed authorization
    # invalidates the whole order, taking the app/auth certs down with it.
    # An `if` rather than `[ -n ... ] && cf_upsert_a ...` so a false test as
    # the last statement can't trip `set -e`.
    if [ -n "${admin_host:-}" ]; then
      cf_upsert_a "$admin_host" "$lb_ip"
    else
      echo "ADMIN_HOST not set — skipping the admin host's A record"
    fi
  else
    echo "CF_API_TOKEN not set — skipping the Cloudflare DNS update (point DNS by hand if needed)"
  fi

  echo "installing/upgrading cert-manager"
  helm repo add jetstack https://charts.jetstack.io >/dev/null
  helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace --wait \
    --set crds.enabled=true

  # Flux controllers (same as the beekeepingit-gitops README's dev prerequisite
  # — imperative, not GitOps-managed, per ADR-0009). Base controllers only: Flux
  # is read-only (D-27/ADR-0018 dropped image-automation).
  echo "installing Flux controllers"
  flux install
  flux check
}
