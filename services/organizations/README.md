# services/organizations

The **organizations** service. It owns the `organizations.organizations`
(tenant root) and `organizations.memberships` tables, resolves a user to its
**active membership** — the `organization_id` + `role` the request runs under
— for the shared auth middleware's org/role resolution
([auth.md](../../docs/architecture/auth.md) §5.1 steps 2–3,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.2/§5.2),
and exposes the client-facing organization-creation surface (FR-ONB-2,
FR-TEN-2, NFR-ROL-1, [#26](https://github.com/TiagoJVO/beekeepingit/issues/26)).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go module,
linked through the repo-root `go.work`.

## Surface

| Route                                       | Auth         | Purpose                                                                                                                                                               |
| ------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /v1/organizations`                    | Keycloak JWT | Create an organization; the caller becomes its first `admin` member, in the same DB transaction (D-3). No org-membership requirement — this is how a caller gets one. |
| `GET /v1/organizations/me`                  | Keycloak JWT | The caller's own organization, resolved from their active membership. `404` when the caller has none yet — the signal the client's org-completion gate probes for.    |
| `GET /v1/organizations/{orgId}`             | Keycloak JWT | An organization by id; `404` (not `403`) unless `{orgId}` is the caller's own org (ADR-0002 — the path never widens scope).                                           |
| `GET /internal/memberships/active?user_id=` | Keycloak JWT | Resolve a user → `{ organization_id, role }` for its active membership / 404. **Internal only** — never routed through the gateway.                                   |
| `GET /healthz`, `GET /readyz`               | none         | Liveness / readiness (readiness pings the DB).                                                                                                                        |

The three `/v1` routes run behind Keycloak authn only, **not** the shared
`authn.NewOrgResolver` — see `api/organizations.go`'s package doc for why (a
brand-new caller must reach `POST /organizations`, and looping back into this
same service's own membership table over HTTP would be redundant).

History recording (FR-HIS-1) for organization create/update is deferred —
tracked in [#165](https://github.com/TiagoJVO/beekeepingit/issues/165), same as
profile's (#25).

## Configuration

Inherits the template's env vars (see
[servicetemplate/README.md](../servicetemplate/README.md)). Additionally:

| Variable                | Notes                                                                                                          |
| ----------------------- | -------------------------------------------------------------------------------------------------------------- |
| `SEED_DEV_DATA`         | When `true`, idempotently seeds the dev/CI org + active admin membership (`shared/devseed`). Dev/CI only.      |
| `INTERNAL_IDENTITY_URL` | The identity service's in-cluster base URL — resolves the caller's `sub` to a `user_id` (auth.md §5.1 step 1). |

## Development

```sh
cd services/organizations
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # httptest + testcontainers/Postgres integration test (needs Docker)
```

Schema changes go through **both** `store/migrations/*.sql` (goose) and
`store/sqlc/schema.sql` (sqlc) — keep them in lock-step.
