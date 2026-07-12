# services/apiaries

The **apiaries** service — owner of apiary records
([#23](https://github.com/TiagoJVO/beekeepingit/issues/23),
[#31](https://github.com/TiagoJVO/beekeepingit/issues/31)). It owns the
`apiaries.apiaries`, `apiaries.sync_conflict_log` and `apiaries.audit_log`
tables, exposes the client-facing **REST CRUD** surface (FR-AP-1), and
implements the internal sync **validate/apply** path with
server-authoritative last-write-wins (LWW), conflict logging, tombstones and
idempotency ([sync.md](../../docs/architecture/sync.md) §4–§5,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.1/§4.6).
`location` is PostGIS `geography(Point, 4326)` (D-6, data-model.md §6),
GIST-indexed for the proximity ordering a later wave (#33) builds on top.
`notes` is optional free-text (FR-AP-8, #196), shown on the client's apiary
detail screen when present.

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md); history
recording via [`services/shared/history`](../shared/README.md). Its own Go
module, linked through the repo-root `go.work`.

## Surface

| Route                            | Auth                 | Purpose                                                                                 |
| -------------------------------- | -------------------- | --------------------------------------------------------------------------------------- |
| `GET /v1/apiaries`               | OIDC JWT + org scope | Cursor-paginated list of the org's live apiaries (FR-AP-7).                             |
| `GET /v1/apiaries/{apiaryId}`    | OIDC JWT + org scope | One apiary, or 404.                                                                     |
| `POST /v1/apiaries`              | OIDC JWT + org scope | Create (client-supplied `id`); `Idempotency-Key`-safe re-send; 201 + `Location`/`ETag`. |
| `PATCH /v1/apiaries/{apiaryId}`  | OIDC JWT + org scope | Partial update; optional `If-Match`; 200 + `ETag`.                                      |
| `DELETE /v1/apiaries/{apiaryId}` | OIDC JWT + org scope | Soft-delete (tombstone); optional `If-Match`; 204.                                      |
| `POST /internal/sync/validate`   | JWT + org scope      | Dry-run a batch; 200 if all valid, else 422 RFC 9457 with field detail. **Internal.**   |
| `GET /healthz`, `GET /readyz`    | none                 | Liveness / readiness.                                                                   |
| `POST /internal/sync/apply`      | JWT + org scope      | Apply a batch in one tx: LWW + conflict log + tombstones + idempotency. **Internal.**   |

The REST write routes (`POST`/`PATCH`/`DELETE`) are for **online-only/direct
callers** (Admin App, scripts) — the field PWA never calls them directly;
every client write rides the local-first sync path (§4.4). Both write paths
(REST, `api/write.go`, and sync-apply, `api/sync.go`) validate identically
and record history identically.

### Apply semantics (sync.md §4)

- **LWW** on device `updated_at`: strictly-newer incoming wins; on equal/older
  the server value is kept.
- **Conflict log**: every LWW loss writes a `sync_conflict_log` row (winner
  `server`, both payloads retained) — the non-destructive safety net.
- **Idempotency**: a re-sent op that would change nothing is `applied` (no-op,
  no conflict), so PowerSync's forward-retry is safe.
- **Tombstones**: `delete` sets `deleted_at`; tombstoned rows drop out of reads
  and propagate down via sync.
- **History**: every applied create/update/delete, on both the REST and the
  sync-apply write path, appends one `apiaries.audit_log` row in the same
  local transaction as the domain write (FR-HIS-1, `services/shared/history`)
  — idempotent replays and LWW losses write no domain audit row (history.md
  §4/§6).

## Configuration

Inherits the template's env vars. Additionally the org-resolver needs the
in-cluster URLs of the resolve services:

| Variable                     | Notes                            |
| ---------------------------- | -------------------------------- |
| `INTERNAL_IDENTITY_URL`      | e.g. `http://identity:8080`      |
| `INTERNAL_ORGANIZATIONS_URL` | e.g. `http://organizations:8080` |

## Development

```sh
cd services/apiaries
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # httptest + testcontainers/Postgres (postgis/postgis image — the location
                # column needs the extension); REST CRUD + LWW/conflict/idempotency/tombstone
                # matrix, history (#59/#31), cross-org access-denial (#28), and org-scoping
                # schema check (#30)
```

## Tenancy (FR-TEN-2, #28/#30)

Every route runs behind OIDC authn + `authn.NewOrgResolver` + `authn.RequireRole` (#28), and
every query is scoped by the server-derived `organization_id` (`api/common.go`'s `requireOrg` —
never a client-supplied value). `apiaries.apiaries`, `apiaries.sync_conflict_log` and
`apiaries.audit_log` all carry `organization_id`, verified both by reading the migrations and by
an automated schema check (`TestApiariesSchema_EveryOwnedTableCarriesOrganizationID`, using
[`dbaccess.UnscopedTables`](../shared/dbaccess/tenancy.go)) so a future migration can't drop the
column unnoticed. Cross-organization access attempts (read, list, and both write paths — REST and
sync-apply) are covered by `TestApiariesSlice_CrossOrg_*`/`TestApiariesRest_CrossOrg_*` in
`main_test.go`. See
[ADR-0002](../../docs/adr/0002-multi-tenancy.md) for the tenancy model and the RLS-deferral
decision.
