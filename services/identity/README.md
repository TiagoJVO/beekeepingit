# services/identity

**Identity** service, started for the M0 walking skeleton
([#23](https://github.com/TiagoJVO/beekeepingit/issues/23)) and extended with
client-facing profile onboarding
([#25](https://github.com/TiagoJVO/beekeepingit/issues/25), FR-ONB-1). It owns
the `identity.users` table — the local projection of an OIDC-authenticated
principal (D-7) — and resolves an OIDC subject to a user, the first step of
the shared auth middleware's org/role resolution
([auth.md](../../docs/architecture/auth.md) §5.1 step 1,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.2/§5.2).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md) (goose migrations +
sqlc typed queries). Its own Go module, linked through the repo-root `go.work`.

## Surface

| Route                              | Auth     | Purpose                                                                                                                                                     |
| ---------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /internal/users/by-sub/{sub}` | OIDC JWT | Resolve an OIDC `sub` → `{ user_id, oidc_sub, name, email, locale }` / 404. **Internal only** — never routed through the gateway.                           |
| `GET /v1/profile`                  | OIDC JWT | Get (or lazily create, on first login) the caller's own profile. No org resolver — profile exists before any organization does.                             |
| `PATCH /v1/profile`                | OIDC JWT | Partially update the caller's own profile (`name`/`email`/`locale`); 422 on invalid fields. Returns the full profile, including derived `profile_complete`. |
| `GET /healthz`, `GET /readyz`      | none     | Liveness / readiness (readiness pings the DB).                                                                                                              |

History recording (FR-HIS-1, [#165](https://github.com/TiagoJVO/beekeepingit/issues/165)):
profile create-on-first-seen (`GET /v1/profile`) and update (`PATCH /v1/profile`) each write one
`identity.audit_log` row in the same local transaction as the `identity.users` write
([docs/architecture/history.md](../../docs/architecture/history.md) §4). Unlike the other
services' `audit_log`, `organization_id` is nullable and always `NULL` here — `identity.users` is
a global, non-org-owned entity (history.md §9). Append-only immutability (DB role grants) is out
of scope here — that's [#62](https://github.com/TiagoJVO/beekeepingit/issues/62).

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
