# The Flutter web bundle is built ahead of `docker build` — by the CI build
# step and the local deploy script — via `flutter build web` (client/ has no
# cross-module deps, so this is straightforward). This image just serves the
# static bundle with SPA fallback for client-side (go_router) routes.
#
#   flutter build web --dart-define=GATEWAY_BASE_URL=...   # + PowerSync web assets (see README)
#   docker build -t <image> client
# Non-root (EPIC-14 #89, NFR-SEC-1, trivy-config DS-0002): use nginx's OWN
# unprivileged image rather than making stock `nginx:alpine` run non-root by
# hand. The stock image's master starts as root (to bind :80 and drop
# privileges per-worker) and its entrypoint scripts write into
# /etc/nginx/conf.d and /var/cache/nginx at startup — forcing it non-root +
# `readOnlyRootFilesystem` makes those writes fail and the container
# crash-loops before nginx ever listens (observed on the #224 CI k3d run:
# pwa CrashLoopBackOff, "connection refused" on :8080). `nginxinc/
# nginx-unprivileged` is purpose-built for exactly this: it already runs as
# uid/gid 101, listens on 8080 (not 80), writes its pidfile to /tmp, ships no
# top-level `user` directive (which errors when the master isn't root), and
# its entrypoint tolerates a read-only root filesystem. Same nginx, same
# config surface — just the rootless variant.
FROM nginxinc/nginx-unprivileged:1.27-alpine
# Patch base-image OS packages (openssl et al.) to the latest Alpine security
# releases so the image clears the CI Trivy HIGH/CRITICAL gate (#88). Needs
# root briefly for apk; the base image's own trailing `USER nginx` (uid 101)
# is re-asserted below after the COPYs.
USER root
RUN apk --no-cache upgrade
# Our server block replaces the base image's default. This image's
# conf.d/default.conf already listens on 8080 as uid 101; ours does the same
# (see nginx.conf) and adds the SPA fallback + security headers.
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/web /usr/share/nginx/html
USER nginx
EXPOSE 8080
