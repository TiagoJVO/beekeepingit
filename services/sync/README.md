# services/sync

The thin, stateless **sync** service — the offline-sync write-back seam of the
walking skeleton ([#23](https://github.com/TiagoJVO/beekeepingit/issues/23),
[walking-skeleton.md](../../docs/architecture/walking-skeleton.md) §4.3,
[sync.md](../../docs/architecture/sync.md) §3.4/§6). It **owns no domain data**
and holds no schema credentials — so, unlike the other services, it needs no
database.

Contract: [`contracts/openapi/sync.openapi.yaml`](../../contracts/openapi/sync.openapi.yaml).
Stamped from [`services/servicetemplate`](../servicetemplate/README.md); its own
Go module, linked through the repo-root `go.work`.

## Surface

| Route                          | Auth                     | Purpose                                                                                            |
| ------------------------------ | ------------------------ | -------------------------------------------------------------------------------------------------- |
| `GET /v1/sync/token`           | OIDC JWT + org scope     | Mint a short-TTL RS256 sync token carrying the `organization_id` claim PowerSync parameterizes on. |
| `POST /v1/sync/batch`          | OIDC JWT + org scope     | The single write-back seam: validate-all → apply via owning services, forwarding the bearer.       |
| `GET /internal/sync/jwks.json` | none (public key set)    | JWKS PowerSync validates sync tokens against. **Internal** — never via the gateway.                |
| `GET /healthz`, `GET /readyz`  | none                     | Liveness / readiness.                                                                              |

The coordinator fans out to exactly one owning service today (`apiaries`), but
implements the two-phase validate-then-apply contract as specified, so adding a
second owning service later changes nothing here (sync.md §6.3). A validation
reject relays the owning service's `422` (nothing written); a post-validation
failure returns `502` and heals on PowerSync's idempotent forward-retry.

## Configuration (env vars)

| Variable                      | Required | Default          | Notes                                                                                           |
| ----------------------------- | -------- | ---------------- | ----------------------------------------------------------------------------------------------- |
| `SERVICE_NAME`                | yes      | —                | OTel service name / logger name.                                                                |
| `HTTP_ADDR`                   | no       | `:8080`          |                                                                                                 |
| `LOG_LEVEL`                   | no       | `info`           |                                                                                                 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | no       | `localhost:4317` |                                                                                                 |
| `OIDC_ISSUER_URL`             | yes      | —                | OIDC issuer (validates the caller's access token).                                              |
| `OIDC_AUDIENCE`               | yes      | —                | Expected access-token audience.                                                                 |
| `INTERNAL_IDENTITY_URL`       | yes      | —                | Identity service base URL (org resolver).                                                       |
| `INTERNAL_ORGANIZATIONS_URL`  | yes      | —                | Organizations service base URL (org resolver).                                                  |
| `INTERNAL_APIARIES_URL`       | yes      | —                | Apiaries service base URL (coordinator target).                                                 |
| `SYNC_TOKEN_ISSUER`           | yes      | —                | `iss` stamped into minted sync tokens.                                                          |
| `SYNC_TOKEN_AUDIENCE`         | yes      | —                | `aud` PowerSync expects on the sync token.                                                      |
| `SYNC_TOKEN_TTL`              | no       | `5m`             | Sync-token lifetime (Go duration).                                                              |
| `SYNC_TOKEN_PRIVATE_KEY`      | no       | _(generated)_    | PEM RSA key. Omitted ⇒ ephemeral key (dev/CI only); production supplies a stable key (EPIC-14). |

## Development

```sh
cd services/sync
go build ./...
go test ./...   # unit tests (token minting/JWKS + coordinator orchestration) + an OpenAPI
                # contract test against the real HTTP surface (main_test.go) — no Docker needed
```
