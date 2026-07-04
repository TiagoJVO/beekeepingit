# services/shared

Cross-cutting Go libraries that keep domain services from being coupled to a specific
database technology or cloud/hosting environment (**NFR-ARC-2**), per
[`docs/architecture/service-decomposition.md`](../../docs/architecture/service-decomposition.md)
§7 and [ADR-0011](../../docs/adr/0011-infra-abstraction-object-storage-db-access.md). This is
not a deployable service — it's a library other `services/*` modules import.

- **[`objectstore`](objectstore/)** — an S3-compatible object storage adapter. Talks to
  MinIO today; the same code talks to AWS S3 or another S3-compatible provider later, purely
  by changing `Config`.
- **[`dbaccess`](dbaccess/)** — a Postgres data-access layer: a typed query layer (`pgx` +
  `sqlc`) and versioned migrations (`goose`) behind a `Config`, instead of raw
  provider-specific calls scattered across services. `dbaccess/sqlc/` is a minimal reference
  migration + typed queries other services can pattern-match — not a real domain feature.

Both packages take an explicit `Config` struct (dependency injection) rather than loading
their own environment/config — that's the shared **Go service template**'s job
([#20](https://github.com/TiagoJVO/beekeepingit/issues/20)), which will import these packages
for its own data-access AC. See [FOLLOWUPS.md](../../FOLLOWUPS.md).

## The seam: switching endpoints is a config change, not a code change

Both adapters are constructed once, from a `Config`, and used identically afterwards. Swapping
where they point — local dev vs. a different provider — never touches adapter code, only the
values below (typically populated from environment variables/secrets by the caller, e.g.
`services/shared/example_test.go`-style wiring, or the future service template's config
loader):

```go
// Local dev: MinIO + the CNPG Postgres cluster from infra/helm/beekeepingit.
devObjectStoreCfg := objectstore.Config{
    Endpoint:  "minio:9000",
    AccessKey: os.Getenv("S3_ACCESS_KEY"),
    SecretKey: os.Getenv("S3_SECRET_KEY"),
    UseSSL:    false,
}
devDBCfg := dbaccess.Config{
    Host:     "postgres",
    User:     os.Getenv("DB_USER"),
    Password: os.Getenv("DB_PASSWORD"),
    Database: "beekeepingit",
    SSLMode:  "require",
}

// A different S3-compatible provider / managed Postgres later — same call sites,
// only the Config values differ.
prodObjectStoreCfg := objectstore.Config{
    Endpoint:  "s3.eu-central-1.amazonaws.com",
    AccessKey: os.Getenv("S3_ACCESS_KEY"),
    SecretKey: os.Getenv("S3_SECRET_KEY"),
    UseSSL:    true,
    Region:    "eu-central-1",
}
prodDBCfg := dbaccess.Config{
    Host:     os.Getenv("DB_HOST"), // e.g. a managed Postgres endpoint
    User:     os.Getenv("DB_USER"),
    Password: os.Getenv("DB_PASSWORD"),
    Database: "beekeepingit",
    SSLMode:  "require",
}

store, err := objectstore.New(devObjectStoreCfg) // or prodObjectStoreCfg
pool, err := dbaccess.Connect(ctx, devDBCfg)      // or prodDBCfg
```

The integration tests (`objectstore/store_test.go`, `dbaccess/dbaccess_test.go`) are the
executable proof the adapters work end-to-end — they build the same `Config` from an ephemeral
testcontainers endpoint instead of the dev cluster's, exercising the exact same code path. The
unit tests (`objectstore/objectstore_test.go`, `dbaccess/config_test.go`) cover the pure-logic
paths that don't need a live endpoint: fail-fast validation and DSN rendering/escaping.

## Development

```sh
cd services/shared
go build ./...
go test ./...              # unit tests + testcontainers integration tests (needs Docker)
golangci-lint run ./...

# Regenerate the sqlc reference queries after editing dbaccess/sqlc/queries or schema.sql:
cd dbaccess/sqlc && sqlc generate
```

No message broker exists in this stack yet (`requirements/tech-stack.md`) — when one is
introduced, it should follow the same pattern: a small adapter behind a `Config`, connection
details injected, never hardcoded.
