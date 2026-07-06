# The Flutter web bundle is built ahead of `docker build` — by the CI build
# step and the local deploy script — via `flutter build web` (client/ has no
# cross-module deps, so this is straightforward). This image just serves the
# static bundle with SPA fallback for client-side (go_router) routes.
#
#   flutter build web --dart-define=GATEWAY_BASE_URL=...   # + PowerSync web assets (see README)
#   docker build -t <image> client
FROM nginx:1.31-alpine
# Patch base-image OS packages (openssl et al.) to the latest Alpine security
# releases so the image clears the CI Trivy HIGH/CRITICAL gate (#88).
RUN apk --no-cache upgrade
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/web /usr/share/nginx/html
EXPOSE 80
