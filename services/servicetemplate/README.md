# services/servicetemplate

The shared Go service template ([#20](https://github.com/TiagoJVO/beekeepingit/issues/20)): health
checks, config loading, structured logging, OpenTelemetry, JWT/JWKS auth, and a consistent error
format, layered on top of [`services/shared`](../shared/README.md)'s infra abstractions (DB
access). See [ADR-0015](../../docs/adr/0015-shared-go-service-template.md) for the design
rationale and [`docs/architecture/auth.md`](../../docs/architecture/auth.md) §4 for the JWT
design this implements. This is not a deployable service itself — it's a library other
`services/*` modules import, plus a runnable [`example/`](example/) demonstrating the wiring.

Org-scoped tenancy resolution (which organization, which role) is now also here, as the
`authn.NewOrgResolver` middleware layered on top of `authn.Claims` — it resolves the request's
`organization_id` + `role` from membership via internal calls to the `identity`/`organizations`
services (walking-skeleton.md §4.2). Role-differentiated authorization (the `admin` vs `user`
policy matrix) is still a later concern (EPIC-01/#28).

## Packages

| Package        | What it provides                                                                                                                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config`       | Env-var loader; aggregates every missing required value into one error                                                                                                                                                                      |
| `problem`      | RFC 9457 error format (`application/problem+json`) + panic-recovery middleware                                                                                                                                                              |
| `health`       | `Checker` registry backing `/healthz` (liveness) and `/readyz` (readiness)                                                                                                                                                                  |
| `logging`      | `log/slog` JSON to stdout, fanned out to the OTel collector, trace-correlated                                                                                                                                                               |
| `otelboot`     | Bootstraps OTel traces/metrics/logs (OTLP/gRPC) against the collector                                                                                                                                                                       |
| `authn`        | JWT/JWKS bearer-token verification middleware (any OIDC provider, via `coreos/go-oidc`); `NewOrgResolver` enriches `Claims` with `organization_id`/`role` from membership (§4.2); `authn/authtest` is a reusable fake OIDC issuer for tests |
| (root)         | Wires the above into a `chi` HTTP server: `New`/`Mount`/`Router`/`Run`/`Shutdown`                                                                                                                                                           |
| `example`      | Runnable reference (`go run ./example`) every domain service's `main.go` copies                                                                                                                                                             |
| `contracttest` | Validates a real HTTP response against a `contracts/openapi/*.openapi.yaml` spec ($ref/allOf-aware) — the "contract tests at boundaries" helper (#153); used from a service's own integration tests, e.g. `services/apiaries/main_test.go`  |

## Configuration (env vars)

| Variable                          | Required | Default          | Notes                                         |
| --------------------------------- | -------- | ---------------- | --------------------------------------------- |
| `SERVICE_NAME`                    | yes      | —                | Used as the OTel `service.name` + logger name |
| `HTTP_ADDR`                       | no       | `:8080`          |                                               |
| `LOG_LEVEL`                       | no       | `info`           | `debug` \| `info` \| `warn` \| `error`        |
| `OTEL_EXPORTER_OTLP_ENDPOINT`     | no       | `localhost:4317` | `otel-collector:4317` in-cluster (ADR-0013)   |
| `OIDC_ISSUER_URL`                 | yes      | —                | e.g. `https://auth.../o/beekeepingit/`        |
| `OIDC_AUDIENCE`                   | yes      | —                | Expected client id (checked against `aud`)    |
| `DB_HOST` / `DB_USER` / `DB_NAME` | yes      | —                | Passed through to `dbaccess.Config`           |
| `DB_PORT`                         | no       | `5432`           |                                               |
| `DB_PASSWORD`                     | no       | _(empty)_        |                                               |
| `DB_SSLMODE`                      | no       | `require`        | `disable` for local/test Postgres             |

## The `go.work` workspace

`services/servicetemplate` is a **separate Go module** from `services/shared` (per ADR-0011's own
follow-up), linked via the repo-root [`go.work`](../../go.work) so local development resolves
`services/shared/dbaccess` from the working tree rather than a published version. Outside the
workspace (e.g. importing just this module elsewhere) `go.mod`'s own `require` line still resolves
the public `github.com/TiagoJVO/beekeepingit/services/shared` module, so the module stands alone
too — `go.work` only changes what _this monorepo's_ tooling resolves to.

## Running the example

`example/` needs a reachable Postgres and an OIDC issuer (a local Authentik instance, or point
`OIDC_ISSUER_URL` at any OIDC-compliant discovery endpoint for a quick smoke test):

```sh
cd services/servicetemplate
export SERVICE_NAME=example DB_HOST=localhost DB_USER=beekeepingit DB_NAME=beekeepingit \
       DB_SSLMODE=disable OIDC_ISSUER_URL=https://auth.example/application/o/beekeepingit/ \
       OIDC_AUDIENCE=beekeepingit-example
go run ./example
```

`GET /v1/example-items` (bearer token required) lists rows from
`services/shared/dbaccess`'s `platform_example.items` reference table; `/healthz` and `/readyz`
need no token.

## Development

```sh
cd services/servicetemplate
go build ./...
go test ./...              # unit tests + testcontainers/httptest integration tests (needs Docker)
golangci-lint run ./...
```
