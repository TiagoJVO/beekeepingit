# 0002 — Multi-tenancy: organization_id discriminator + app-layer scoping (+ optional RLS)

- **Status:** Accepted
- **Date:** 2026-06-28
- **Issue / Epic:** #105 / #103 (EPIC-DESIGN) · **Milestone:** M0
- **Requirements:** FR-TEN-1, FR-TEN-2, NFR-SEC-1, NFR-SCA-1, NFR-ARC-3
- **Decisions:** [D-1](../../requirements/decisions.md), [D-6](../../requirements/decisions.md)
- **Context:** [C-1](../../requirements/context.md#c-1--single-organization-now-multi-organization-later)
  (single org now, many later), [Q-TEN](../../requirements/open-questions.md)
- **Design doc:** [data-model.md](../architecture/data-model.md)

## Context

FR-TEN-2 makes the **Organization the unit of ownership**: apiaries, activities, journeys and
todos belong to the org, all members share them, and users must only ever access **their own
org's** data. Context [C-1](../../requirements/context.md#c-1--single-organization-now-multi-organization-later)
says we run a **single org now** but must **not block** the multi-org path. The architecture is
microservices over **one Postgres cluster with a schema per service** (D-6), and an **offline
sync** engine replicates a per-device slice (D-6, #106). We must choose a tenancy model that is
safe, cheap to run for one org, and scales to many without a rewrite.

## Decision

Use a **shared-schema, discriminator-column** tenancy model:

1. **Every org-owned row carries `organization_id`** (a soft reference to `organizations.id`).
   The only exception is the **global `identity.users`** record (a person, not org property);
   org membership is modelled separately in `organizations.memberships`.
2. **Mandatory application-layer scoping** is the primary control: a shared Go middleware
   resolves the caller's `organization_id` (from the verified token + membership — authZ detail
   in #109) and **every query is org-scoped**. A query without an org filter is a bug.
3. **Optional Postgres Row-Level Security (RLS)** as defense-in-depth: set `app.current_org` per
   request and apply `USING (organization_id = current_setting('app.current_org')::uuid)`
   policies on owned tables, so a forgotten filter fails safe.
4. **Org-scoped sync publication:** the engine only replicates a device's `organization_id`
   slice (and user-scoped where activity ownership requires), so tenancy holds on-device too.

## Consequences

**Positive**
- **One model serves 1 org and N orgs** with no structural change — directly satisfies C-1
  ("don't block multi-org") and NFR-SCA-1 while staying cheap for the single-org present.
- Keeps the **single cluster** (NFR-ARC-3) and a **consolidated, simple sync publication**
  (one predicate: `organization_id`), which schema/db-per-tenant would complicate.
- **Split-later intact:** because tenancy is a column (not a schema/db), the
  [#104](../architecture/service-decomposition.md) "split a schema into its own database later"
  path is unaffected.
- RLS gives a **fail-safe backstop** for the worst tenancy bug (cross-org data leak).

**Negative / risks**
- **Discipline-dependent:** isolation relies on every query being scoped. **Mitigations:** the
  shared query layer enforces it, optional RLS backstops it, and tenancy is part of the
  Definition of Done + tests (NFR-TST).
- **Noisy-neighbour at scale:** shared tables mean one org's volume can affect others
  eventually. Not a concern at single-org v1; partitioning by `organization_id` or promoting a
  large tenant to its own database are available later (the split-later path).
- **RLS session-var plumbing** must be set on every pooled connection; if adopted, it needs care
  with connection poolers. Kept **optional** for that reason — app-layer scoping is the
  guarantee, RLS the backstop.

## Alternatives considered

- **Schema-per-tenant:** strong isolation, but multiplies schemas/migrations, complicates the
  sync publication, and is pure over-build for a single org. **Rejected** for v1; reachable
  later for a tenant that needs hard isolation.
- **Database-per-tenant:** strongest isolation, heaviest ops; contradicts NFR-ARC-3's single
  cluster and the consolidated sync. **Rejected** for v1.
- **RLS-only (no app scoping):** elegant, but makes correctness depend on the session var being
  set on every path and offers no in-app clarity. **Rejected** as the *primary* control; kept as
  the optional backstop layered under app scoping.

## Follow-ups

- #106 — tombstones, LWW clock and **org-scoped sync publication** mechanics.
- #109 — how `organization_id` is derived from the token + membership (the authZ that feeds
  layer 2).
- Per-service build (EPIC-00 #20, EPIC-13) — implement scoping in the shared query layer and add
  tenancy tests; decide whether to enable RLS.
