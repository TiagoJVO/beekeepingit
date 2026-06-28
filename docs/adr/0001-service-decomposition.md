# 0001 — Service decomposition & bounded contexts

- **Status:** Accepted
- **Date:** 2026-06-28
- **Issue / Epic:** #104 / #103 (EPIC-DESIGN) · **Milestone:** M0
- **Requirements:** NFR-ARC-1, NFR-ARC-2, NFR-ARC-3
- **Decisions:** [D-1](../../requirements/decisions.md#d-1--v1-uses-a-full-microservices-architecture),
  D-5, D-6, D-7, D-9, D-10
- **Open questions:** [Q-SCALE](../../requirements/open-questions.md)
  (resolved by D-1), [Q-SYNC](../../requirements/open-questions.md#q-sync--offline-conflict-resolution-strategy)
- **Design doc:** [service-decomposition.md](../architecture/service-decomposition.md)

## Context

[D-1](../../requirements/decisions.md#d-1--v1-uses-a-full-microservices-architecture) commits v1
to a **full microservices architecture** and names service decomposition a "first-class planning
task". This must be reconciled with two forces pulling the other way:

- Context [C-1](../../requirements/context.md#c-1--single-organization-now-multi-organization-later)
  and the [Q-SCALE](../../requirements/open-questions.md)
  recommended-default warn that full microservices is likely **over-engineering for a single-org
  v1** and suggest a modular monolith with clean internal boundaries.
- Offline-first (FR-OF-1, D-6) wants a **consolidated, replicable** store, while microservices
  want **per-service** stores.

We need concrete service boundaries, data ownership, and a single-cluster topology (NFR-ARC-3)
that the M0 build (EPIC-00) and platform (EPIC-13) can deploy onto.

## Decision

Adopt **eight domain microservices**, each owning **exactly one Postgres schema** on a **single
shared PostgreSQL + PostGIS cluster** (D-6), with the **sync engine replicating only the
org/user-scoped slice** to devices:

`identity` · `organizations` · `apiaries` · `activities` · `journeys` · `todos` · `ai` ·
`history`

Boundary rules (full rationale and diagrams in the
[design doc](../architecture/service-decomposition.md)):

1. **Schema-per-service; a service writes only its own schema.** No cross-schema writes, no
   cross-schema foreign keys, no server-side cross-schema joins.
2. **Cross-context references are by ID** (soft references), with integrity enforced in
   application logic; composite reads are served by the **client's replicated slice** or by
   **API composition**.
3. **Tenancy is universal:** every owned row carries `organization_id`; all queries are
   org-scoped (RLS optional, detail in #105/#109).
4. **`ai` never writes domain data directly** (AI write-safety): its own DB access is read-only,
   scoped and parameterized; it **proposes** writes that are **user-confirmed** and executed by
   the **owning service** via its normal API. It is the only service that calls an external
   system (the cloud LLM). (D-11)
5. The **admin** context is a **client** (React Admin App) over `identity` + `organizations`
   management endpoints — **not** a separate microservice (it owns no data).
6. **Billing/quotas** (D-4), **import/export** (EPIC-09), and **on-device AI** (D-10) are **not**
   v1 services — kept as boundaries/stubs only.

The decomposition's by-product — the **Helm umbrella subchart list** — is handed to EPIC-13
(#83) in the [design doc §7](../architecture/service-decomposition.md#7-single-cluster-topology--helm-subchart-list-nfr-arc-3--d-6).

## Consequences

**Positive**

- Clean, independently-deployable boundaries that match the named bounded contexts; the target
  architecture is in place from day one (the explicit intent of D-1).
- Schema-per-service on one cluster keeps the **offline slice tractable** and makes "split a
  schema into its own database later" a **migration, not a rewrite** — preserving NFR-ARC-2/3.
- The `ai` no-direct-write rule (reads scoped/parameterized; writes proposed → user-confirmed →
  owner-executed) and per-row `organization_id` keep the security/tenancy guarantees (NFR-AI-1,
  NFR-AI-4, FR-TEN) enforceable and testable.

**Negative / risks**

- **Operational over-engineering for one org** (the C-1/Q-SCALE concern): eight services, a
  gateway, Keycloak, Postgres, a sync engine and an observability stack are a lot to run for a
  single Portuguese beekeeping org. Accepted as a deliberate D-1 trade-off.
- **Tight core-domain coupling:** `apiaries`/`activities`/`journeys` are highly interdependent;
  splitting them risks chatty inter-service reads. **Mitigation:** offline-first means most
  composite reads happen on the client's replicated slice, not server-to-server; if server-side
  chatter still hurts, **merge them into one `field-records` service first**.
- **Sync write-back vs. ownership:** letting the sync engine apply offline writes directly to
  authoritative tables can bypass per-service validation. This is the sharpest cross-service
  risk and is owned by **#106** (the write path must respect ownership rule 1). D-12 also requires
  each push to be **atomic** (all-or-nothing) with client validation parity and a notify-and-fix
  flow — but a multi-service push **can't share one DB transaction** (rule 1), so atomicity needs
  **saga/compensation or a per-service transactional batch + coordinator**.
- **AI-proposed writes add an injection / over-reach surface:** an LLM fed untrusted NL/voice
  could propose a wrong or over-broad action. **Mitigation:** mandatory user confirmation,
  owner-side validation/authz, and context-scope limits — the `ai` service never executes the
  write itself (NFR-AI-4, D-11; detailed write-action model deferred to EPIC-08 design).

## Alternatives considered

- **Modular monolith / few coarse services** (the Q-SCALE recommended-default): lower
  cost/complexity for a single org, same logical boundaries, split later. **Rejected** because
  it contradicts D-1 — but retained as the **escape hatch**: because boundaries are already
  schema-clean and reference-by-ID, collapsing services into a modular monolith (or merging the
  core domain) is a deployment change, not a redesign, if operational cost proves unjustified.
- **Database-per-service now** (instead of schema-per-service): maximal isolation, but breaks
  the offline-sync reconciliation (the sync engine needs a consolidated publication) and adds
  cost for no v1 benefit. **Rejected** for v1 per D-6; reachable later via migration.
- **A dedicated `admin` microservice:** rejected — the admin app owns no domain data, so it adds
  a deployable with no data boundary; a thin BFF can be introduced later if needed.

## Follow-ups

Sets the boundaries for the rest of EPIC-DESIGN: #105 (data model), #106 (sync/conflict), #107
(history), #108 (API contracts), #109 (authN/authZ), #110 (walking-skeleton design); and gates
EPIC-13 (#83 umbrella chart) and EPIC-00 (#23 walking skeleton).
