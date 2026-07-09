# services/organizations

The **organizations** service. It owns the `organizations.organizations`
(tenant root), `organizations.memberships` and `organizations.invitations`
tables, resolves a user to its **active membership** (the `organization_id`
and `role` the request runs under) for the shared auth middleware's org/role
resolution ([auth.md](../../docs/architecture/auth.md) §5.1 steps 2–3,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.2/§5.2),
and exposes the client-facing organization-creation surface (FR-ONB-2,
FR-TEN-2, NFR-ROL-1, [#26](https://github.com/TiagoJVO/beekeepingit/issues/26))
plus admin-only membership + email invitations (FR-ONB-3, D-3,
[#27](https://github.com/TiagoJVO/beekeepingit/issues/27)).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go module,
linked through the repo-root `go.work`.

## Surface

| Route                                                         | Auth     | Purpose                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /v1/organizations`                                      | OIDC JWT | Create an organization; the caller becomes its first `admin` member, in the same DB transaction (D-3). `409` if the caller already has an active membership elsewhere.                                                                                                       |
| `GET /v1/organizations/me`                                    | OIDC JWT | The caller's own organization, resolved from their active membership. Before a `404`, auto-accepts a pending invitation matching the caller's own JWT-verified, verified-flag-gated email (FR-ONB-3) if one exists — the signal the client's org-completion gate probes for. |
| `GET /v1/organizations/{orgId}`                               | OIDC JWT | An organization by id; `404` (not `403`) unless `{orgId}` is the caller's own org (ADR-0002 — the path never widens scope).                                                                                                                                                  |
| `GET /v1/organizations/{orgId}/members`                       | OIDC JWT | List the org's members (admin only, `403` for a non-admin member). Keyset-paginated.                                                                                                                                                                                         |
| `GET /v1/organizations/{orgId}/invitations`                   | OIDC JWT | List the org's invitations, any status (admin only). Keyset-paginated.                                                                                                                                                                                                       |
| `POST /v1/organizations/{orgId}/invitations`                  | OIDC JWT | Invite an email to join at a role (default `user`, admin only). `409` if that email already has a pending invitation to this org.                                                                                                                                            |
| `DELETE /v1/organizations/{orgId}/invitations/{invitationId}` | OIDC JWT | Revoke a still-pending invitation (admin only); `404` if it's already resolved or doesn't exist in this org.                                                                                                                                                                 |
| `GET /internal/memberships/active?user_id=`                   | OIDC JWT | Resolve a user → `{ organization_id, role }` for its active membership / 404. **Internal only** — never routed through the gateway.                                                                                                                                          |
| `GET /healthz`, `GET /readyz`                                 | none     | Liveness / readiness (readiness pings the DB).                                                                                                                                                                                                                               |

All `/v1` routes run behind OIDC authn only, **not** the shared
`authn.NewOrgResolver` — see `api/organizations.go`'s package doc for why (a
brand-new caller must reach `POST /organizations`, and looping back into this
same service's own membership table over HTTP would be redundant).

Member removal, invitation expiry/re-invite, and admin transfer are **not**
built — D-3 and FR-ONB-3 both flag these as still-open detail beyond "implement
the core invite/join now."

History recording (FR-HIS-1) for organization/membership/invitation changes is
deferred — tracked in [#165](https://github.com/TiagoJVO/beekeepingit/issues/165),
same as profile's (#25).

## Configuration

Inherits the template's env vars (see
[servicetemplate/README.md](../servicetemplate/README.md)). Additionally:

| Variable                | Notes                                                                                                                                                                                                                                                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SEED_DEV_DATA`         | When `true`, idempotently seeds the dev/CI org + active admin membership (`shared/devseed`). Dev/CI only.                                                                                                                                                                                                              |
| `INTERNAL_IDENTITY_URL` | The identity service's in-cluster base URL — resolves the caller's `sub` to a `user_id` (auth.md §5.1 step 1). The accept-on-login path (#27) matches invitations against the JWT's own verified `email` claim, **not** identity's resolve response — see `api/organizations.go`'s `ResolvedUser` doc comment for why. |

## Development

```sh
cd services/organizations
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # httptest + testcontainers/Postgres integration test (needs Docker)
```

Schema changes go through **both** `store/migrations/*.sql` (goose) and
`store/sqlc/schema.sql` (sqlc) — keep them in lock-step.
