# The service binary is compiled ahead of `docker build` — by the CI build
# step and the local deploy script — using the Go workspace (go.work), which
# resolves the sibling `shared`/`servicetemplate` modules from the tree. The
# per-service build context (services/<name>/) can't do that resolution itself,
# so this image simply packages the prebuilt static binary. Minimal distroless,
# non-root (NFR-SEC).
#
#   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o app .
#   docker build -t <image> services/organizations
FROM gcr.io/distroless/static-debian12:nonroot
COPY app /app
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app"]
