<!-- Generated: 2026-07-14 | Files scanned: 147 | Token estimate: ~1000 -->

# Backend Codemap

Go microservices (`go.work`), one module each, chi router, sqlc + pgx + goose.
All bootstrap from `services/servicetemplate`; `services/shared` is a library.
Router: `github.com/go-chi/chi/v5`. Errors: RFC 9457 problem+json.

## Middleware chain

```text
servicetemplate.New:  otelhttp → Recover → RequestID → RequestLogger
   + GET /healthz, GET /readyz            (unauthenticated)
Domain routes mounted behind:  authnMW(JWT) → orgMW(org-resolver) → roleMW(RequireRole)
   authn.NewMiddleware  services/servicetemplate/authn/authn.go   (verify OIDC JWT)
   authn.NewOrgResolver services/servicetemplate/authn/resolver.go(sub→user, →membership)
   authn.RequireRole    services/servicetemplate/authn/authz.go   (role gate)
```

## Routes → handler (file)

### identity (main.go; authnMW)

```text
GET   /v1/profile              → getProfile      api/profile.go
PATCH /v1/profile              → updateProfile   api/profile.go
GET   /internal/users/by-sub/{sub} → getUserBySub   api/users.go
GET   /internal/users/names        → getUsersByNames api/users.go (batch user_id→name, #44)
```

### organizations (main.go; authnMW; resolver→identity)

```text
POST   /v1/organizations                         → createOrganization  api/organizations.go
GET    /v1/organizations/me                       → getMyOrganization   api/organizations.go
GET    /v1/organizations/{orgId}                  → getOrganization     api/organizations.go
GET    /v1/organizations/{orgId}/members          → listMembers         api/invitations.go (admin)
GET    /v1/organizations/{orgId}/members/names    → listMemberNames     api/invitations.go (any member, #44)
GET    /v1/organizations/{orgId}/invitations      → listInvitations     api/invitations.go
POST   /v1/organizations/{orgId}/invitations      → createInvitation    api/invitations.go (admin)
DELETE /v1/organizations/{orgId}/invitations/{id} → revokeInvitation    api/invitations.go (admin)
GET    /internal/memberships/active               → getActiveMembership api/memberships.go
```

### apiaries (main.go; authnMW→orgMW→RequireRole(admin,user))

```text
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

### activities (main.go; authnMW→orgMW→RequireRole(admin,user))

```text
POST   /internal/activities/validate → validateHandler  api/validate.go (stateless, #38)
POST   /v1/activities                → createActivity   api/write.go (#39; online-only/direct callers)
PATCH  /v1/activities/{id}           → updateActivity   api/write.go (#40; ownership re-verified only if apiary_id sent)
DELETE /v1/activities/{id}           → deleteActivity   api/write.go (#41; soft-delete/tombstone)
POST   /internal/sync/validate       → validateActivityBatch api/sync.go (#39/#40/#41; put/patch/delete)
POST   /internal/sync/apply          → applyActivityBatch    api/sync.go (#39/#40/#41; LWW + tombstone)
```

#38's scope was the data model (`api/types.go`'s type registry + JSONB
attribute validation) + tenancy — the validate-only route proved the wiring.
#39 added the create write path; #40/#41 extend the same REST + sync-apply
surface with edit and delete (a tombstone, never a hard delete — the
PowerSync Sync Rules filter `deleted_at IS NULL`). Every write path that
touches `apiary_id` verifies it belongs to the caller's org via
`api/apiaries_client.go`'s `ApiaryVerifier` (an HTTP call to apiaries' own
`GET /v1/apiaries/{id}` — this service has no DB access to the apiaries
schema) BEFORE writing anything; `performed_by` is derived server-side from
claims, never the client (FR-TEN-2). List is #42/#43.

### sync (main.go; no DB; authnMW→orgMW on /v1)

```text
GET   /v1/sync/token           → TokenHandler   api/handlers.go (mint short-TTL org token)
POST  /v1/sync/batch           → BatchHandler   api/handlers.go → Coordinator (coordinator.go)
GET   /internal/sync/jwks.json → JWKSHandler    api/handlers.go (unauth; PowerSync validates)
```

`Coordinator.handle` (api/coordinator.go): groups ops by owning service via
`entity_type` (`activity` → activities, #39; everything else → apiaries),
validate-all → if every group 200s, apply-all → merge results. Single-group
batches (the common case) use the byte-identical pre-#39 fast path. 422 from
any group aborts the whole push (nothing written anywhere); upstream error →
502 (batch stays queued, idempotent retry).

## Service → store mapping (per DB-backed service)

```text
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
