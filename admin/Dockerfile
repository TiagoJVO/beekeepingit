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
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
EXPOSE 80
