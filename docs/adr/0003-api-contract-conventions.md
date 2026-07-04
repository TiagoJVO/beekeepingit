# 0003 — API & inter-service contract conventions (REST + OpenAPI, contract-first)

- **Status:** Accepted
- **Date:** 2026-07-01
- **Issue / Epic:** #108 / #103 (EPIC-DESIGN) · **Milestone:** M0
- **Requirements:** NFR-ARC-1, NFR-MNT-1, NFR-SEC-1, NFR-TST-1, NFR-I18N-1, NFR-RL-1
- **Decisions:** [D-1](../../requirements/decisions.md#d-1--v1-uses-a-full-microservices-architecture)
  (microservices → inter-service contracts), [D-5](../../requirements/decisions.md) (Go/Flutter/React),
  [D-7](../../requirements/decisions.md) (Keycloak JWT)
- **Open questions:** Q-SYNC (resolved → [sync.md](../architecture/sync.md) / [ADR-0006](0006-sync-conflict-resolution.md)),
  Q-AUTH / Q-ROLE (resolved → [ADR-0004](0004-authn-authz.md))
- **Design doc:** [api-contracts.md](../architecture/api-contracts.md) ·
  **Contracts:** [`contracts/openapi/`](../../contracts/openapi/)

## Context

[D-1](../../requirements/decisions.md#d-1--v1-uses-a-full-microservices-architecture) commits v1
to **full microservices**, so eight services ([#104](../architecture/service-decomposition.md))
must present **one coherent API surface** to two clients (Flutter PWA, React Admin App) and be
independently buildable and **contract-testable** (NFR-ARC-1, NFR-MNT-1, NFR-TST-1). The
tech-stack marks the API style **"Proposed"** ("REST + OpenAPI (client); gRPC optional
inter-service") — this ADR **decides** it and fixes the cross-cutting conventions (naming,
errors, pagination, versioning, auth/tenancy) every service epic will otherwise reinvent
inconsistently. It builds directly on the tenancy model ([ADR-0002](0002-multi-tenancy.md)) and
the offline-first data model ([data-model.md](../architecture/data-model.md)).

## Decision

Adopt **contract-first REST + OpenAPI 3.1** for all client-facing APIs, with these conventions
(full detail and skeletons in the [design doc](../architecture/api-contracts.md)):

1. **Contract-first:** the OpenAPI document is authored and reviewed before code; stubs, typed
   clients and contract tests are generated from it, and CI fails on code/spec drift.
2. **Resource-oriented REST:** plural `kebab-case` nouns, collection+item, shallow ownership
   nesting, cross-context references **by id** (never by nesting or DB access), non-CRUD actions
   as sub-resources/commands. `snake_case` JSON and query params.
3. **One error format — [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) Problem Details**
   (`application/problem+json`) with a stable machine `code` and field-level `errors[]`.
4. **Cursor (keyset) pagination** with a standard `{ data, page:{ next_cursor, limit } }`
   envelope; explicit `snake_case` filters; allow-listed `sort`.
5. **Versioning:** **major version in the URL path (`/vN`)**, owned by the gateway; only
   backward-compatible changes within a major; breaking changes ship a new major alongside the
   old and go through deprecate → `Sunset` → next major.
6. **Auth & tenancy:** Keycloak **JWT bearer** on every operation (D-7); the caller's
   `organization_id` is derived **from the token + membership** and is **never** a client
   parameter ([ADR-0002](0002-multi-tenancy.md)); out-of-scope ids return `404`.
7. **Offline-aware verbs:** client-generated UUIDs, `Idempotency-Key` on `POST`, `ETag`/`If-Match`
   optimistic concurrency, `DELETE` = soft-delete/tombstone — aligning the contract with the
   sync write-back path (#106, D-12).
8. **Inter-service:** minimal by design; **default REST/JSON** for the rare synchronous internal
   call, **gRPC only for a measured hot path** (protobuf contract under `contracts/proto/` if/when
   adopted), **async events/outbox for reactions** (#107). No cross-service DB access.
9. **Layout:** `contracts/openapi/<service>.openapi.yaml` + a shared
   `_shared/components.openapi.yaml` **contract template**; skeletons for the first services
   (`apiaries`, `organizations`) committed now.

## Consequences

**Positive**

- **One consistent, standard surface:** every service looks the same to clients and testers;
  RFC 9457 + OpenAPI are interoperable IETF/OAI standards with mature tooling (codegen, mock,
  contract test) — directly serves NFR-MNT-1 and NFR-TST-1.
- **Contract-first enables the walking skeleton (#110):** clients and servers are generated
  from a committed spec, so front- and back-end can proceed in parallel against a fixed boundary.
- **Offline & tenancy are baked into the contract**, not bolted on: idempotency/ETag/soft-delete
  match the sync model, and org-from-token keeps the [ADR-0002](0002-multi-tenancy.md) guarantee
  un-bypassable from the client.
- **Evolution is safe for slow field clients:** path-major versioning + a breaking-change CI diff
  let old PWApp installs keep working while `/v2` rolls out.

**Negative / risks**

- **Discipline-dependent:** contract-first only holds if CI enforces spec↔code parity and
  breaking-change detection. **Mitigation:** lint + `oasdiff` + codegen + contract tests wired in
  EPIC-13 (tracked in [FOLLOWUPS.md](../../FOLLOWUPS.md)); until then specs are hand-linted.
- **Split-file `$ref` needs bundling** before codegen/publish, and `security` scheme names can't
  be cross-file `$ref`s (each spec re-declares `bearerAuth` as a `$ref` to the shared def).
  Accepted — it is the standard contract-first workflow and keeps a single source of truth.
- **Two protocols if gRPC ever lands:** a second contract toolchain. **Mitigation:** gRPC is
  gated behind _measured_ need (none in v1), so we don't pay it speculatively.
- **Cursor pagination** is less trivial to implement than offset and can't random-access a page.
  Accepted: it is correct under concurrent writes and matches indexed keys/sync; offline reads
  dominate anyway.

## Alternatives considered

- **Bespoke JSON error shape** instead of RFC 9457: one less spec to read, but reinvents a solved
  problem and loses tooling/interop. **Rejected** — the standard is strictly better and testable.
- **Header or media-type versioning** (`Accept: …;v=2`) instead of URL path: cleaner URLs, but
  harder to route at the gateway, cache, and eyeball in field logs, and worse for slow-updating
  clients. **Rejected** for v1; the path major is simplest and most operable.
- **Offset/limit pagination:** simplest and random-access, but unstable under concurrent inserts
  and costly at depth. **Rejected** as the default; may appear behind a fixed admin report if ever
  needed.
- **gRPC-first (or GraphQL) for everything:** gRPC is excellent east-west but poor for browser
  clients and adds toolchain cost with almost no east-west traffic to justify it; GraphQL adds a
  gateway/resolver layer and N+1/authorization complexity a small team doesn't need. **Rejected**
  — REST+OpenAPI for clients, gRPC reserved for a proven hot path.
- **RPC-style verbs in URLs** (`/getApiary`): **Rejected** — non-idiomatic REST, poor cacheability,
  inconsistent with resource modeling.

## Follow-ups

- **#106 / SP-1** — the sync write-back protocol over these REST writes (atomic push, D-12).
- **#109** — JWT validation placement, claims→`organization_id`, admin scope (Q-AUTH/Q-ROLE).
- **#107** — the async event/outbox contract for cross-service reactions (history capture).
- **EPIC-13** — CI: OpenAPI lint, `oasdiff` breaking-change gate, server/client codegen, and
  contract tests at boundaries (tracked in [FOLLOWUPS.md](../../FOLLOWUPS.md)).
- **Per service epic** — author the full spec from the template as each service is built
  (`identity`, `activities`, `journeys`, `todos`, `ai`, `history`).
