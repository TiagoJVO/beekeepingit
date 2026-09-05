# The Vite production bundle is built ahead of `docker build` — by the CI build step
# (.github/workflows/build-publish.yml) and any local deploy — via `npm run build`
# (admin/ has no cross-module deps, so this is straightforward). This image just serves
# the static bundle with SPA fallback for client-side routes.
#
#   npm ci && npm run build            # produces admin/dist/
#   docker build -t <image> admin
# Same base as the field app (client/Dockerfile). This was nginx:1.27-alpine until
# 2026-09-05 — Alpine 3.21.3, three branches behind the 3.24.1 the client already
# ran, for no reason anyone recorded. The two images serve the same way (static
# bundle, SPA fallback), so they now track one tag and get patched together.
FROM nginx:1.31-alpine
# Patch base-image OS packages to the latest Alpine security releases so the image clears
# the CI Trivy HIGH/CRITICAL gate (#88).
RUN apk --no-cache upgrade
# Drop the dynamic modules the official image ships but this deployment never
# loads. This is not tidying: `nginx-module-image-filter` drags in
# libgd -> libxpm -> libxt -> libsm -> libuuid, and libuuid is the ONLY package
# in this image built from the util-linux source. That one shared library is why
# Trivy failed every image build on 2026-09-05 with 7 HIGH util-linux CVEs
# (CVE-2026-53612/53613/53614/76642/78408/78409/78410, fixed in 2.42.3-r0) —
# advisories against mount(8), libmount and nsenter, none of which are installed
# here at all (/bin/mount is a busybox symlink). The `apk upgrade` above cannot
# clear them: 2.42.3-r0 is not in the v3.24 repository yet, and there is no newer
# base to move to — nginx:1.31-alpine and nginx:1.31.5-alpine3.24 are the same
# digest, on the latest stable Alpine 3.24.1. Removing the package that pulls the
# library in fixes the finding at its source instead of suppressing it.
#
# Safe because this image loads NO dynamic module: stock /etc/nginx/nginx.conf
# carries no `load_module` line, and the nginx.conf copied below uses no
# image_filter, xslt, geoip or js_ directive. The `nginx` package itself depends
# only on musl, libcrypto/libssl, pcre2 and zlib, so serving is untouched. If a
# directive ever needs one of these, add the package back with its `load_module`.
#
# The grep is the guarantee rather than the hope: /lib/apk/db/installed is the
# exact file Trivy reads, so a future base image that keeps libuuid alive by some
# other path fails the build here instead of failing the scan minutes later.
RUN apk --no-cache del \
      nginx-module-image-filter \
      nginx-module-xslt \
      nginx-module-geoip \
      nginx-module-njs \
      nginx-module-acme \
 && ! grep -q '^P:libuuid$' /lib/apk/db/installed
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
