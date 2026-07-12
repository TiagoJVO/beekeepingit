# The Flutter web bundle is built ahead of `docker build` — by the CI build
# step and the local deploy script — via `flutter build web` (client/ has no
# cross-module deps, so this is straightforward). This image just serves the
# static bundle with SPA fallback for client-side (go_router) routes.
#
#   flutter build web --dart-define=GATEWAY_BASE_URL=...   # + PowerSync web assets (see README)
#   docker build -t <image> client
FROM nginx:1.27-alpine
# Patch base-image OS packages (openssl et al.) to the latest Alpine security
# releases so the image clears the CI Trivy HIGH/CRITICAL gate (#88).
#
# Non-root (EPIC-14 #89, NFR-SEC-1, trivy-config DS-0002): nginx's master
# process normally starts as root to bind :80 and drop privileges per-worker;
# running the whole container as a fixed non-root uid instead means binding a
# port >1024 (8080). `nginx` (uid/gid 101) already exists in this base image
# — reused rather than inventing a new one. It only needs READ access to the
# static site (default COPY permissions already give every user read), so no
# ownership change is needed there; it DOES need write access to its own
# runtime dirs (cache/temp + pidfile) for a read-only root filesystem to
# work, which the Deployment provides as emptyDir mounts with a matching
# `fsGroup: 101` (charts/pwa/templates/deployment.yaml) — a volume mount
# overrides whatever this image layer would chown anyway, so that's set
# there, not here.
RUN apk --no-cache upgrade
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/web /usr/share/nginx/html
USER nginx:nginx
EXPOSE 8080
