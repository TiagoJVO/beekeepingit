# services/apiaries

The **apiaries** service — owner of the walking skeleton's trivial record
([#23](https://github.com/TiagoJVO/beekeepingit/issues/23)). It owns the
`apiaries.apiaries` table and its `apiaries.sync_conflict_log`, exposes the
client-facing **read** surface, and implements the internal sync
**validate/apply** path with server-authoritative last-write-wins (LWW),
conflict logging, tombstones and idempotency
([sync.md](../../docs/architecture/sync.md) §4–§5,
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.1/§4.6).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go module,
linked through the repo-root `go.work`.

## Surface

| Route                          | Auth                 | Purpose                                                                               |
| ------------------------------ | -------------------- | ------------------------------------------------------------------------------------- |
| `GET /v1/apiaries`             | OIDC JWT + org scope | Cursor-paginated list of the org's live apiaries (FR-AP-7).                           |
| `GET /v1/apiaries/{apiaryId}`  | OIDC JWT + org scope | One apiary, or 404.                                                                   |
| `POST /internal/sync/validate` | JWT + org scope      | Dry-run a batch; 200 if all valid, else 422 RFC 9457 with field detail. **Internal.** |
| `GET /healthz`, `GET /readyz`  | none                 | Liveness / readiness.                                                                 |
| `POST /internal/sync/apply`    | JWT + org scope      | Apply a batch in one tx: LWW + conflict log + tombstones + idempotency. **Internal.** |

**No client-facing REST write handlers** (`POST/PATCH/DELETE /v1/apiaries`) —
the field client is local-first through sync (§4.4); online writes are EPIC-02
([#31](https://github.com/TiagoJVO/beekeepingit/issues/31)).

### Apply semantics (sync.md §4)

- **LWW** on device `updated_at`: strictly-newer incoming wins; on equal/older
  the server value is kept.
- **Conflict log**: every LWW loss writes a `sync_conflict_log` row (winner
  `server`, both payloads retained) — the non-destructive safety net.
- **Idempotency**: a re-sent op that would change nothing is `applied` (no-op,
  no conflict), so PowerSync's forward-retry is safe.
- **Tombstones**: `delete` sets `deleted_at`; tombstoned rows drop out of reads
  and propagate down via sync.
- **Audit seam**: the apply transaction has a clearly-marked point where EPIC-07
  (#59/#61) adds the in-tx `audit_log` INSERT — history is out of scope here.

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
go test ./...   # httptest + testcontainers/Postgres; LWW/conflict/idempotency/tombstone matrix,
                # cross-org access-denial (#28), and org-scoping schema check (#30)
```

## Tenancy (FR-TEN-2, #28/#30)

Every route runs behind OIDC authn + `authn.NewOrgResolver` + `authn.RequireRole` (#28), and
every query is scoped by the server-derived `organization_id` (`api/common.go`'s `requireOrg` —
never a client-supplied value). `apiaries.apiaries`/`apiaries.sync_conflict_log` both carry
`organization_id`, verified both by reading the migration and by an automated schema check
(`TestApiariesSchema_EveryOwnedTableCarriesOrganizationID`, using
[`dbaccess.UnscopedTables`](../shared/dbaccess/tenancy.go)) so a future migration can't drop the
column unnoticed. Cross-organization access attempts (read, list, and a sync-apply write) are
covered by `TestApiariesSlice_CrossOrg_*` in `main_test.go`. See
[ADR-0002](../../docs/adr/0002-multi-tenancy.md) for the tenancy model and the RLS-deferral
decision.
