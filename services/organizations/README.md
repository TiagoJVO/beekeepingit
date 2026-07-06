# services/organizations

Minimal **organizations** service for the M0 walking skeleton
([#23](https://github.com/TiagoJVO/beekeepingit/issues/23)). It owns the
`organizations.organizations` (tenant root) and `organizations.memberships`
tables, and resolves a user to its **active membership** — the
`organization_id` + `role` the request runs under — the second step of the
shared auth middleware's org/role resolution
([auth.md](../../docs/architecture/auth.md) §5.1 steps 2–3,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.2/§5.2).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go module,
linked through the repo-root `go.work`.

## Surface

| Route                                       | Auth         | Purpose                                                                                                                             |
| ------------------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `GET /internal/memberships/active?user_id=` | Keycloak JWT | Resolve a user → `{ organization_id, role }` for its active membership / 404. **Internal only** — never routed through the gateway. |
| `GET /healthz`, `GET /readyz`               | none         | Liveness / readiness (readiness pings the DB).                                                                                      |

## Configuration

Inherits the template's env vars (see
[servicetemplate/README.md](../servicetemplate/README.md)). Additionally:

| Variable        | Notes                                                                                                     |
| --------------- | --------------------------------------------------------------------------------------------------------- |
| `SEED_DEV_DATA` | When `true`, idempotently seeds the dev/CI org + active admin membership (`shared/devseed`). Dev/CI only. |

## Development

```sh
cd services/organizations
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # httptest + testcontainers/Postgres integration test (needs Docker)
```

Schema changes go through **both** `store/migrations/*.sql` (goose) and
`store/sqlc/schema.sql` (sqlc) — keep them in lock-step.
