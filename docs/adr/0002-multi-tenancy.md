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
   in [ADR-0004](0004-authn-authz.md)) and **every query is org-scoped**. A query without an org filter is a bug.
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
  set on every path and offers no in-app clarity. **Rejected** as the _primary_ control; kept as
  the optional backstop layered under app scoping.

## Follow-ups

- #106 — tombstones, LWW clock and **org-scoped sync publication** mechanics.
- `organization_id` derivation from the token + membership (the authZ that feeds layer 2) —
  **designed in [ADR-0004](0004-authn-authz.md)** / [auth.md](../architecture/auth.md) (#109).
- Per-service build (EPIC-00 #20, EPIC-13) — implement scoping in the shared query layer and add
  tenancy tests; decide whether to enable RLS.

## RLS decision (layer 2, resolved in #30)

**Decision: RLS stays deferred (not enabled) for v1.** This isn't leaving the "optional" call
unaddressed — it's a deliberate, reasoned deferral with a concrete, codebase-specific reason
beyond the general "connection pooler" risk this ADR already flagged:

- **Every service connects to Postgres as its own least-privilege `<schema>_svc` role (D-6,
  `infra/helm/beekeepingit/charts/postgres/templates/cluster.yaml`), and that SAME role also
  RUNS THE MIGRATIONS that `CREATE TABLE` the schema's own tables** (`dbaccess.Migrate` and
  `dbaccess.Connect` share one `Config`/DSN — `services/servicetemplate/config/config.go`). That
  makes `<schema>_svc` the **table owner** for every table it queries.
- **Postgres table owners bypass RLS by default** — a plain
  `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` would be **silently ineffective** for exactly the
  role that runs every application query, giving a false sense of a working backstop. Making
  RLS actually bind here needs
  `FORCE ROW LEVEL SECURITY` (still bypassed by a table's owner unless forced) **and** either (a)
  separating table ownership from the querying role (a bootstrap/infra change — who owns the
  table vs. who's granted DML — not a per-service code change) or (b) auditing that `FORCE` is
  set on every owned table and re-verifying it on every migration.
- Even with that fixed, RLS's session-variable plumbing (`SET app.current_org`) is only safe
  through a **pooled** connection (`pgxpool.Pool`, used by every service, `services/shared/dbaccess/pool.go`)
  if scoped with `SET LOCAL` inside an explicit transaction per request. Today only the handlers
  that already need atomicity for another reason run inside a transaction (`apiaries`'s sync-apply
  write path for LWW+conflict-log atomicity; `organizations`'s `POST /organizations` for the
  create-org-and-membership invariant) — every plain single-statement read (`GET /v1/apiaries`,
  `GET /organizations/{orgId}`, etc., the majority of the current request volume) runs a bare
  query with no transaction wrapper at all, so adopting RLS would mean adding one to every such
  handler across every service, not just the already-transactional write paths.
- **What's already real, working, and tested instead:** layer 1 (mandatory app-layer scoping,
  every query parameterized by the middleware-resolved `organization_id`) and layer 3 (the
  PowerSync `by_organization` bucket definition — `infra/helm/beekeepingit/charts/powersync/values.yaml`
  — filters every synced row by the sync token's `organization_id` claim) are both implemented and
  covered by cross-org tests (`services/apiaries/main_test.go`'s `TestApiariesSlice_CrossOrg_*`,
  `services/organizations/organizations_test.go`'s `TestGetOrganization_OtherOrg_Returns404`).
  `dbaccess.UnscopedTables` (`services/shared/dbaccess/tenancy.go`) automates the "every owned row
  carries `organization_id`" check per-service in CI, so layer 1's precondition doesn't silently
  regress on a future migration either.
- **Revisit when:** a genuine multi-org tenant lands (C-1's "later"), a compliance/pen-test finding
  demands defense-in-depth beyond layer 1+3, or the table-ownership-vs-query-role split gets
  addressed for an unrelated reason (e.g. adopting a migration-runner role distinct from the
  service's own DML role) — at that point `FORCE ROW LEVEL SECURITY` + the `SET LOCAL`-per-transaction
  work becomes a much smaller, additive change instead of a wholesale connection-handling rework.

This resolves #30's "optional Postgres RLS is either enabled or explicitly documented as a
deferred defense-in-depth layer with a rationale" AC.
