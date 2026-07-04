# Rule: Coding standards & testing

## Language conventions

- **Go** (backend services): idiomatic Go (`gofmt`/`vet`, small packages, explicit error
  handling). Use a shared service template (health, config, structured logging, tracing,
  JWT middleware, consistent error format, DB access). DB via a typed query layer;
  versioned migrations.
- **TypeScript / React** (admin app): strict TypeScript, lint + format on commit, function
  components + hooks, a typed API client.
- **Dart / Flutter** (client): follow Effective Dart and the project lint config; keep
  business logic out of widgets; design every screen for offline + EN/PT + accessibility.
- **SQL / Postgres**: parameterized queries only; every owned table carries
  `organization_id`; PostGIS for geo; JSONB for per-activity-type attributes.

## API & contracts

- Client-facing APIs are **REST + OpenAPI** (contract-first); keep spec and code in sync.
  Inter-service calls may use gRPC where it helps. Consider contract tests at boundaries.

## Testing (NFR-TST)

- Add/adjust tests with every change. Go: unit + integration (containerized Postgres).
  Flutter: widget + integration. Admin: component + key e2e flows. Cover offline/sync paths
  and the **AI write-safety guarantees** (no direct AI writes; AI-proposed mutations require
  explicit user confirmation and execute via the owning service's validated, audited API).
  A change isn't done until its tests pass in CI.

## Security & data (NFR-SEC, NFR-CMP)

- No secrets in the repo; load server-side (`EPIC-14`). Validate all input; protect against
  SQLi/XSS/CSRF. Cloud AI must go through the consent/GDPR path (`Q-AICLOUD`) — no org data
  leaves the device without consent + a no-training/DPA-backed provider.

## Style

- Match the surrounding code's conventions. Conventional Commits; small, reviewable PRs.
  See [CONTRIBUTING.md](../../CONTRIBUTING.md).
