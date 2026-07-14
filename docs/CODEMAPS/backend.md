<!-- Generated: 2026-07-14 | Files scanned: 147 | Token estimate: ~1000 -->

# Backend Codemap

Go microservices (`go.work`), one module each, chi router, sqlc + pgx + goose.
All bootstrap from `services/servicetemplate`; `services/shared` is a library.
Router: `github.com/go-chi/chi/v5`. Errors: RFC 9457 problem+json.

## Middleware chain

```
servicetemplate.New:  otelhttp → Recover → RequestID → RequestLogger
   + GET /healthz, GET /readyz            (unauthenticated)
Domain routes mounted behind:  authnMW(JWT) → orgMW(org-resolver) → roleMW(RequireRole)
   authn.NewMiddleware  services/servicetemplate/authn/authn.go   (verify OIDC JWT)
   authn.NewOrgResolver services/servicetemplate/authn/resolver.go(sub→user, →membership)
   authn.RequireRole    services/servicetemplate/authn/authz.go   (role gate)
```

## Routes → handler (file)

### identity (main.go; authnMW)

```
GET   /v1/profile              → getProfile      api/profile.go
PATCH /v1/profile              → updateProfile   api/profile.go
GET   /internal/users/by-sub/{sub} → getUserBySub api/users.go
```

### organizations (main.go; authnMW; resolver→identity)

```
POST   /v1/organizations                         → createOrganization  api/organizations.go
GET    /v1/organizations/me                       → getMyOrganization   api/organizations.go
GET    /v1/organizations/{orgId}                  → getOrganization     api/organizations.go
GET    /v1/organizations/{orgId}/members          → listMembers         api/invitations.go
GET    /v1/organizations/{orgId}/invitations      → listInvitations     api/invitations.go
POST   /v1/organizations/{orgId}/invitations      → createInvitation    api/invitations.go (admin)
DELETE /v1/organizations/{orgId}/invitations/{id} → revokeInvitation    api/invitations.go (admin)
GET    /internal/memberships/active               → getActiveMembership api/memberships.go
```

### apiaries (main.go; authnMW→orgMW→RequireRole(admin,user))

```
GET    /v1/apiaries                    → listApiaries       api/apiaries.go
GET    /v1/apiaries/{id}               → getApiary          api/apiaries.go
GET    /v1/apiaries/{id}/distance      → getApiaryDistance  api/apiaries.go (geo.go, PostGIS)
POST   /v1/apiaries                    → createApiary       api/write.go
PATCH  /v1/apiaries/{id}               → updateApiary       api/write.go (If-Match ETag)
DELETE /v1/apiaries/{id}               → deleteApiary       api/write.go (soft-delete)
POST   /internal/sync/validate         → validateBatch      api/sync.go
POST   /internal/sync/apply            → applyBatch         api/sync.go (counters.go: applyCounterOp)
```

REST writes serve online-only/direct callers (Admin App, scripts); the PWA uses sync.

### sync (main.go; no DB; authnMW→orgMW on /v1)

```
GET   /v1/sync/token           → TokenHandler   api/handlers.go (mint short-TTL org token)
POST  /v1/sync/batch           → BatchHandler   api/handlers.go → Coordinator (coordinator.go)
GET   /internal/sync/jwks.json → JWKSHandler    api/handlers.go (unauth; PowerSync validates)
```

`Coordinator.handle` (api/coordinator.go): POST validate → if 200, POST apply → relay.
422 relayed (nothing written); upstream error → 502 (batch stays queued, idempotent retry).

## Service → store mapping (per DB-backed service)

```
api/*.go (handlers)
  → store/sqlc/gen/*.sql.go   (typed queries, sqlc-generated from queries/*.sql)
  → pgxpool.Pool              (dbaccess.Connect, services/shared/dbaccess/pool.go)
migrations: store/migrations/*.sql (goose) applied at boot via dbaccess.Migrate + migrations_embed.go
schema.sql = sqlc's virtual (codegen-only) schema; mirrors cumulative migrations
```

## Shared building blocks

- `servicetemplate/`: `authn` (JWT/authz/resolver), `config`, `health`, `logging`, `otelboot` (OTel), `problem` (RFC 9457), `contracttest`.
- `shared/`: `dbaccess` (pool, migrate, tenancy), `objectstore` (MinIO), `history` (audit delta), `devseed`.

## Contracts

OpenAPI specs in `contracts/openapi/*.yaml` (apiaries, identity, organizations, sync);
services validate responses against them in tests (`servicetemplate/contracttest`).

See [data.md](data.md) for tables, [dependencies.md](dependencies.md) for the module graph.
