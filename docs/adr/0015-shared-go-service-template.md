# 0015 — Shared Go service template (`services/servicetemplate`)

- **Status:** Accepted
- **Date:** 2026-07-05
- **Issue / Epic:** [#20](https://github.com/TiagoJVO/beekeepingit/issues/20) · EPIC-00 (#1) ·
  **Milestone:** M0
- **Requirements:** [NFR-MNT-1](../../requirements/non-functional-requirements.md),
  [NFR-ARC-1](../../requirements/non-functional-requirements.md),
  [NFR-ARC-2](../../requirements/non-functional-requirements.md),
  [NFR-OBS-1](../../requirements/non-functional-requirements.md)
- **Decisions:** [D-5](../../requirements/decisions.md) (Go backend),
  [D-6](../../requirements/decisions.md) (Postgres + PostGIS, schema-per-service),
  [D-7](../../requirements/decisions.md) (Authentik OIDC)
- **Related ADRs:** [0011-infra-abstraction-object-storage-db-access](0011-infra-abstraction-object-storage-db-access.md)
  (the follow-up this ADR executes), [0013-observability-stack](0013-observability-stack.md)
  (the collector this template exports to), [0004-authn-authz](0004-authn-authz.md) /
  [auth.md](../architecture/auth.md) §4 (the JWT/JWKS design this implements),
  [0003-api-contract-conventions](0003-api-contract-conventions.md) /
  [api-contracts.md](../architecture/api-contracts.md) §7 (the RFC 9457 error format)
- **As-built reference:** [services/servicetemplate/README.md](../../services/servicetemplate/README.md)

## Context

[#20](https://github.com/TiagoJVO/beekeepingit/issues/20) calls for a reusable Go service
template — health checks, config loading, structured logging, OpenTelemetry, JWT/JWKS auth, a
consistent error format, and Postgres access — that every future domain service (`identity`,
`organizations`, `apiaries`, …) bootstraps from, per
[coding-standards.md](../../.claude/rules/coding-standards.md) ("use a shared service template").

ADR-0011 (`services/shared`, #85) deliberately stopped short of env-loading and HTTP-server
concerns so this issue could own them, and explicitly anticipated the shape: **a separate Go
module** that imports `services/shared/dbaccess`, wired via a **`go.work`** — "the first domain
service that needs to import it will need to add one... **#20** ... Wire a `go.work` (or
`replace`) at that point" (ADR-0011 Follow-ups). This ADR executes that plan rather than
revisiting it: `services/shared` stays scoped to infra abstraction (object storage, DB access);
`services/servicetemplate` is the HTTP/service-bootstrap layer built on top of it.

Scope explicitly excludes **org-scoped tenancy authorization** — resolving which organization and
role a caller belongs to (`docs/architecture/auth.md` §5) is `organizations`-service domain data
and is built in EPIC-01. This template only establishes **who** the caller is (JWT authentication),
not **what organization/role** they act as.

## Decision

Add `services/servicetemplate`, a new Go module (`github.com/TiagoJVO/beekeepingit/services/servicetemplate`,
go 1.25.0), linked to `services/shared` via a repo-root **`go.work`** (both `go.work` and
`go.work.sum` committed). It provides:

1. **`config`** — an env-var loader (`Load() (Config, error)`) using only the standard library
   (no config framework — `os.Getenv` is enough for this AC), aggregating every missing required
   variable into one `errors.Join`-ed error instead of failing on the first, per the "fails fast on
   missing required values" AC.
2. **`problem`** — an RFC 9457 Problem Details type mirroring
   [`contracts/openapi/_shared/components.openapi.yaml`](../../contracts/openapi/_shared/components.openapi.yaml)'s
   `Problem` schema exactly, plus canonical constructors (`Unauthorized`, `Forbidden`, `NotFound`,
   `Conflict`, `ValidationFailed`, `Internal`) and a panic-recovery middleware — the single error
   format every layer (authn, health, the sample endpoint) writes through.
3. **`health`** — a `Checker` registry backing `/healthz` (liveness — never runs Checkers, so a
   struggling dependency alone never kills an otherwise-healthy process) and `/readyz`
   (aggregates Checkers, 503 + a `problem.Problem` naming every failing check).
4. **`logging`** — `log/slog` JSON to stdout (readable via `kubectl logs` with no collector
   running) fanned out, via a small hand-rolled `multiHandler` (~15 lines — not worth a
   dependency), to `go.opentelemetry.io/contrib/bridges/otelslog`, so the same log record also
   reaches the OTel collector. A wrapping handler adds `trace_id`/`span_id` attributes from the
   active span context to every record, the field Grafana's Loki↔Tempo `derivedFields`
   correlation keys off (ADR-0013).
5. **`otelboot`** — bootstraps the OTel SDK's Tracer/Meter/LoggerProvider against OTLP/gRPC
   exporters pointed at the collector endpoint (config-driven; `otel-collector:4317` in-cluster
   per ADR-0013, `localhost:4317` by default for local runs), registers a W3C
   tracecontext+baggage propagator, and exposes `Shutdown` to flush all three on exit.
6. **`authn`** — JWT/JWKS verification middleware on `coreos/go-oidc/v3` exactly as
   `docs/architecture/auth.md` §4 specifies: OIDC discovery + JWKS, signature/issuer/audience/
   expiry checked, JWKS cached and refetched on an unrecognized `kid` (key rotation) — proven by a
   test that rotates keys against a hand-crafted discovery+JWKS server. On any failure it writes a
   401 `problem.Problem`. It does **not** resolve org/role (EPIC-01).
7. **Root `servicetemplate` package** — assembles a `chi` router with the middleware chain
   (`otelhttp` instrumentation → panic recovery → request ID → structured request logging),
   registers `/healthz`/`/readyz` **unauthenticated** (kubelet probes carry no bearer token), and
   exposes `Mount`/`Router`/`Run`/`Shutdown` for a caller to add its own (typically JWT-protected)
   routes and run with graceful SIGINT/SIGTERM handling.
8. **`example/`** — a runnable reference (`main.go`) wiring every package together against
   `services/shared/dbaccess`'s existing `platform_example.items` reference table (no new fake
   domain model — reusing ADR-0011's own reference table), exposing `GET /v1/example-items` behind
   the JWT middleware. This is the literal template every future domain service's own `main.go`
   copies from, and it demonstrates the DB-access AC end-to-end (proven by an integration test:
   testcontainers Postgres + a hand-crafted OIDC/JWKS server + a real HTTP round-trip).

**Router: chi** (`github.com/go-chi/chi/v5`), chosen over stdlib `net/http.ServeMux` (lacks a
middleware-chaining/recovery/request-ID ecosystem — would mean hand-rolling both) and `echo`
(bundles its own binder/render/validator surface this repo doesn't need, since contracts are
OpenAPI-generated elsewhere, and a middleware type that doesn't compose as directly with
`otelhttp`). chi's `func(http.Handler) http.Handler` middleware is stdlib-native.

## Consequences

**Positive**

- Every future domain service (`identity`, `organizations`, `apiaries`, …) gets a ready-made,
  tested bootstrap instead of re-deriving health/config/logging/OTel/JWT/error-format wiring per
  service — the actual point of `coding-standards.md`'s "shared service template."
- `services/servicetemplate` is the **first real code** to emit OTel telemetry to the collector
  (ADR-0013's stack so far only proved the pipeline with `telemetrygen`), and the first cross-module
  import inside the monorepo, proving the `go.work` multi-module story every future domain service
  will repeat (each is its own module importing both `services/shared` and `services/servicetemplate`).
- The `authn` package's key-rotation test (mint a token with a key added to the JWKS _after_ the
  middleware's initial fetch) is executable proof of the "refreshed... on an unknown kid" behavior
  `auth.md` §4 specifies, not just an assumption about `go-oidc`'s internals.

**Negative / risks**

- `go.opentelemetry.io/otel/sdk/log` and `otlploggrpc` are still pre-1.0 (`v0.20.0` at
  implementation time) — functionally complete and what the collector's OTLP logs receiver already
  expects, but their API isn't yet guaranteed stable across minor versions the way traces/metrics
  (`v1.44.0`) are. A future OTel Go release could require adjusting `logging`/`otelboot`.
- `go.work` couples module resolution across `services/shared` and `services/servicetemplate` for
  local development; contributors must run Go tooling from a directory under the repo root (or with
  `GOWORK` set) for the workspace override to apply — outside the workspace (e.g. someone vendoring
  just this module), `go.mod`'s own `require` line still resolves the public GitHub repo, so the
  module remains valid standalone too.
- Two modules must now track compatible versions of shared transitive dependencies (`pgx`, OTel
  core) — `go mod tidy` inside the workspace keeps them consistent automatically, but a version bump
  in one module doesn't propagate to the other without running tidy there too.

## Alternatives considered

- **Fold config/logging/OTel/authn/error-format into the existing `services/shared` module**
  instead of a new one. Rejected: ADR-0011 already scoped `services/shared` to infra
  abstraction (object storage, DB access) and explicitly deferred this work to a separate module;
  conflating the two would muddy `services/shared`'s documented single responsibility and skip
  proving the `go.work` multi-module path this early.
- **`echo`** as the HTTP router. Rejected: brings its own binder/render/validator machinery this
  repo doesn't need (OpenAPI-driven contracts are handled elsewhere per
  [api-contracts.md](../architecture/api-contracts.md)) and a middleware interface that doesn't
  compose with `otelhttp` as directly as chi's stdlib-shaped one.
- **A third-party `slog` fan-out/multi-handler library** (e.g. `slog-multi`). Rejected: fanning a
  record out to two child handlers is ~15 lines: not enough surface to justify a dependency.
- **Embedding org-scoped authZ (tenancy, role) into this template now.** Rejected — explicitly out
  of scope per the issue; `organizations` service + membership data doesn't exist yet, and
  `auth.md` designs it as a separate layer built in EPIC-01 on top of the `authn.Claims` this
  template produces.

## Follow-ups

- **EPIC-01** builds the org-scoped authorization middleware (resolve `organization_id` + role from
  `authn.Claims.Sub` + `organizations.memberships`) on top of this package, per
  [auth.md](../architecture/auth.md) §5.
- **Every future domain service** (`identity`, `organizations`, `apiaries`, `activities`,
  `journeys`, `todos`, `ai`, `history` — [service-decomposition.md](../architecture/service-decomposition.md)
  §3) imports `services/servicetemplate` directly (its own module + `go.work` entry), copying
  `example/main.go`'s wiring rather than re-deriving it.
- **#87's telemetry follow-up** (`FOLLOWUPS.md`) — once a real domain service (`#23`, the
  walking-skeleton) wires this template, re-run
  [`infra/observability-smoke-test.sh`](../../infra/observability-smoke-test.sh)'s checks against
  its real traffic instead of `telemetrygen`, per ADR-0013.
