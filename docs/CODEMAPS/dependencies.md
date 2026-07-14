<!-- Generated: 2026-07-14 | Files scanned: 95 | Token estimate: ~950 -->

# Dependencies Codemap

External services, third-party libraries, and shared internal modules.
Deployed via Helm umbrella chart (`infra/helm/beekeepingit`), GitOps by Flux.

## External services (runtime)

| Service                      | Role                                                        | Where configured                            |
| ---------------------------- | ----------------------------------------------------------- | ------------------------------------------- |
| **Authentik**                | OIDC IdP (auth host); replaced Keycloak (ADR-0016)          | charts/authentik; client AppConfig.oidc*    |
| **PowerSync**                | Sync engine — streams Postgres→device, JWKS-verified tokens | charts/powersync (+ Sync Rules)             |
| **Postgres+PostGIS**         | Primary datastore (CloudNativePG operator)                  | charts/postgres; `beekeepingit-postgres-rw` |
| **MinIO**                    | S3-compatible object storage                                | charts/minio; via `shared/objectstore`      |
| **Traefik**                  | Gateway/ingress (`/`, `/v1/*`, `/sync-stream/**`)           | charts/gateway; ADR-0012                    |
| **OTel Collector → Grafana** | Traces/metrics/logs (observability)                         | helm/observability; ADR-0013                |
| **Flux**                     | GitOps reconciliation                                       | infra/gitops; ADR-0009                      |
| **ghcr.io**                  | Container registry (`ghcr.io/tiagojvo/beekeepingit`)        | infra/gitops/image-automation               |

## Inter-service dependency graph (internal HTTP)

```text
client ──JWT──► identity, organizations, apiaries, sync   (all via Traefik /v1/*)
organizations ─► identity            (INTERNAL_IDENTITY_URL, user resolve)
apiaries       ─► identity, organizations   (org-resolver: sub→user, →membership)
sync           ─► identity, organizations   (org-resolver, on /v1)
sync           ─► apiaries            (INTERNAL_APIARIES_URL: /internal/sync/validate+apply)
PowerSync      ─► sync                (validates tokens against /internal/sync/jwks.json)
```

Stable in-cluster DNS `http://<service>:8080`; `sync` holds no DB, no schema creds.

## Backend third-party (Go — go.work modules)

```text
go-chi/chi/v5         HTTP router + middleware
jackc/pgx/v5          Postgres driver + pool
pressly/goose/v3      migrations                  (shared/dbaccess)
minio/minio-go/v7     object storage client       (shared/objectstore)
google/uuid           IDs
go.opentelemetry.io   tracing/metrics/logs        (servicetemplate/otelboot)
go-oidc / JWT         token verification          (servicetemplate/authn)
testcontainers-go     integration tests (Postgres, MinIO)
```

## Frontend third-party (Dart — client/pubspec.yaml)

```text
powersync ^1.18         local-first sync engine + on-device SQLite
flutter_riverpod ^3.3   state management
go_router ^17.2         routing
openid_client ^0.4      OIDC discovery + Auth Code + PKCE (NOT implicit)
http ^1.6               REST (sync token/batch)
flutter_map ^8.2 + latlong2   map view (D-16, OSM/MapLibre tiles)
geolocator ^14          device location (proximity, map marker)
intl · crypto · uuid · meta · web        formatting, PKCE, IDs
fonts: Archivo, Playfair Display (bundled, offline — no google_fonts/CDN)
```

## Shared internal modules

```text
services/servicetemplate  (Go module): authn, config, health, logging, otelboot,
                          problem (RFC 9457), contracttest — every service bootstraps from it
services/shared           (Go module): dbaccess (pool/migrate/tenancy), objectstore,
                          history (audit delta), devseed
contracts/openapi         REST contracts (apiaries, identity, organizations, sync) — contract tests
client/lib/core           app-wide seams: auth, sync (LocalStoreEngine), geo, l10n, config, widgets
```

## Build / tooling

`Taskfile.yml` + `taskfiles/*.yml` (go, dart, web, openapi, repo) · `go.work` (multi-module) ·
`mise.toml` (toolchain) · `lefthook.yml` (git hooks) · `renovate.json` (dep updates) ·
lint/format gate: `task lint` (gofmt, golangci-lint, dart, prettier, markdownlint).

See [backend.md](backend.md) (services), [architecture.md](architecture.md) (topology).
