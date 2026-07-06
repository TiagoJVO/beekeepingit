# services/identity

Minimal **identity** service for the M0 walking skeleton
([#23](https://github.com/TiagoJVO/beekeepingit/issues/23)). It owns the
`identity.users` table — the local projection of a Keycloak-authenticated
principal (D-7) — and resolves an OIDC subject to a user, the first step of
the shared auth middleware's org/role resolution
([auth.md](../../docs/architecture/auth.md) §5.1 step 1,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.2/§5.2).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md) (goose migrations +
sqlc typed queries). Its own Go module, linked through the repo-root `go.work`.

## Surface

| Route                              | Auth         | Purpose                                                                                                                               |
| ---------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /internal/users/by-sub/{sub}` | Keycloak JWT | Resolve an OIDC `sub` → `{ user_id, keycloak_sub, name, email, locale }` / 404. **Internal only** — never routed through the gateway. |
| `GET /healthz`, `GET /readyz`      | none         | Liveness / readiness (readiness pings the DB).                                                                                        |

## Configuration

Inherits the template's env vars (see
[servicetemplate/README.md](../servicetemplate/README.md)). Additionally:

| Variable        | Notes                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------ |
| `SEED_DEV_DATA` | When `true`, idempotently seeds the dev/CI test user (`shared/devseed`). **Dev/CI only** (§4.5). |

## Development

```sh
cd services/identity
sqlc generate -f store/sqlc/sqlc.yaml   # regenerate typed queries after editing store/sqlc
go build ./...
go test ./...   # httptest + testcontainers/Postgres integration test (needs Docker)
```

Schema changes go through **both** `store/migrations/*.sql` (goose, runtime) and
`store/sqlc/schema.sql` (sqlc's codegen view) — keep them in lock-step.
