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
# privileges per-worker) and ships a top-level `user` directive that errors
# when the master isn't root. `nginxinc/nginx-unprivileged` is purpose-built
# for non-root: it runs as uid/gid 101, listens on 8080 (not 80), and ships
# no `user` directive. It still writes a pidfile (/run/nginx.pid) and temp
# dirs (/var/cache/nginx) at startup, so running it under
# `readOnlyRootFilesystem: true` requires writable emptyDir mounts at those
# paths — provided by the Deployment (charts/pwa/templates/deployment.yaml).
# Getting those mounts wrong crash-loops it ([emerg] open()
# "/run/nginx.pid" failed: Read-only file system — the #224 CI failure).
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
