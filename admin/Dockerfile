# The Vite production bundle is built ahead of `docker build` — by the CI build step
# (.github/workflows/build-publish.yml) and any local deploy — via `npm run build`
# (admin/ has no cross-module deps, so this is straightforward). This image just serves
# the static bundle with SPA fallback for client-side routes.
#
#   npm ci && npm run build            # produces admin/dist/
#   docker build -t <image> admin
FROM nginx:1.27-alpine
# Patch base-image OS packages to the latest Alpine security releases so the image clears
# the CI Trivy HIGH/CRITICAL gate (#88).
RUN apk --no-cache upgrade
# Drop the stock IPv6 helper from the entrypoint. It is the ONLY entrypoint
# script that shells out to apk at RUNTIME, and that call is a liability here:
# it runs `apk manifest nginx` to checksum default.conf, which wants the Alpine
# package index, and this deployment denies egress by default. The kubelet then
# liveness-kills a container that never binds :80 (exit 137), in a loop.
#
# It is version-sensitive, which is why it surfaced without any deliberate
# change: v0.0.1-rc11 and rc12 are byte-identical here except that the
# `apk --no-cache upgrade` above pulled apk-tools 3.0.7-r0 -> 3.0.8-r0. rc11
# serves fine; rc12 hung on staging with `ps` inside the pod parked on
# `apk manifest nginx` and no listener. The guard at the top of the script
# (`/proc/net/if_inet6`) is also why this never reproduces locally or in k3d —
# without IPv6 the script exits before ever reaching apk.
#
# Safe to remove: nginx.conf listens on IPv4 :80 and the cluster is IPv4, so
# the IPv6 listen this script would add is dead weight. Removing it makes
# startup depend on nothing but the image itself.
RUN rm -f /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
EXPOSE 80
