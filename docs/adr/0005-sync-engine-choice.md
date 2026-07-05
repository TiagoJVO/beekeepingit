# 0005 — Offline sync engine: PowerSync (self-hosted Open Edition)

- **Status:** Accepted
- **Date:** 2026-07-01
- **Issue / Epic:** #54 (SP-1 spike) / #103 (EPIC-DESIGN) · unblocks #106 · **Milestone:** M0
- **Requirements:** FR-OF-1, FR-OF-2, NFR-ARC-2, NFR-ARC-3, FR-HIS-1, NFR-TST-1
- **Decisions:** [D-6](../../requirements/decisions.md) (resolves the engine pick), [D-12](../../requirements/decisions.md)
  (write-back), [D-5](../../requirements/decisions.md) (Flutter), [D-10](../../requirements/decisions.md) (PWA-first)
- **Questions:** Q-SYNC (conflict policy — default confirmed here; fully resolved in [ADR-0006](0006-sync-conflict-resolution.md) / [sync.md](../architecture/sync.md))
- **Spike:** [SP-1 report](../spikes/sp-1-powersync-vs-electricsql.md) (head-to-head + a working k8s prototype)

## Context

D-6 fixed the data/offline shape (Postgres source of truth, SQLite on device, a per-device
replicated slice) but **deferred the sync engine to spike SP-1**: **PowerSync vs ElectricSQL**,
judged on Flutter/web SDK maturity, PWA offline persistence (wa-sqlite over IndexedDB/OPFS, incl.
iOS durability), conflict handling, self-hosting on the k8s cluster (NFR-ARC-3), and operational
cost. The app is **offline-first** (FR-OF-1/2) with a **Flutter** client (D-5), **PWA first** (D-10),
and writes must flow through the **owning service's** validated/audited API (D-11/D-12).

The two engines have fundamentally different scopes (confirmed against current 2026 sources — see
the SP-1 report):

- **PowerSync** — bidirectional sync: server→client via Sync Rules/buckets into a client **SQLite**;
  client→server via a persistent, crash-surviving **upload queue** that calls a developer **backend
  connector**. First-class **Flutter** SDK incl. **web** (sqlite3.wasm, OPFS with IndexedDB fallback).
  Self-hostable (**Open Edition**, image `journeyapps/powersync-service`, FSL-1.1 → Apache-2.0).
- **ElectricSQL (electric-next)** — a **read-path** sync engine (Postgres → clients as "Shapes" over
  HTTP). Client-side **persistence, the offline write queue, and conflict handling are explicitly out
  of scope** (DIY), and there is **no official Flutter/Dart client** (TypeScript + Elixir only).

## Decision

Adopt **PowerSync**, **self-hosted (Open Edition)** on the k8s cluster, as the offline sync engine.

- **Replication source:** the owning services' Postgres (one cluster, schema-per-service, D-6) with
  `wal_level=logical` and a `powersync` publication; PowerSync bucket storage in a **separate database**.
- **Client slice:** PowerSync **Sync Rules** define the replicated slice — **org-scoped** (and
  user-scoped for activity ownership), the on-device projection of the tenancy model in
  [ADR-0002](0002-multi-tenancy.md). Detailed slice/stream design is #106's.
- **Write path (honors D-11/D-12):** clients write to local SQLite; the upload queue posts batches to
  the **owning service's API** (the connector), which validates, authorizes, org-scopes, and records
  history — PowerSync never writes domain schemas directly.
- **Conflict policy (confirms Q-SYNC default):** **server-authoritative, record-level last-write-wins
  - a conflict log**, implemented in the owning service's write handler. The SP-1 prototype
    demonstrated this end-to-end (older offline edit lost to a newer server value; conflict logged;
    client converged).

## Consequences

**Positive**

- **Fits offline-first + Flutter directly:** full offline reads **and** writes with a durable queue,
  and an official Flutter SDK covering the PWA (web/OPFS) and later native — no rewrite across D-10's
  PWA→Android→iOS rollout (one of the reasons Flutter was kept, D-5).
- **Clean fit with the write-safety model:** the connector = the "writes go through the owning
  service" rule (D-11/D-12); the engine supplies the offline **queue + retry + ordering** primitives.
- **Self-hostable on our cluster** (NFR-ARC-3, NFR-ARC-2) at no license cost for our use (FSL permits
  self-hosting our own app; converts to Apache-2.0). **Proven** in SP-1 on a local kind cluster.
- **Loose Postgres↔client-schema coupling** lets the client slice differ from service schemas.

**Negative / risks**

- **New self-hosted stateful service** to operate (PowerSync service + its storage DB) — added
  ops surface for EPIC-13/EPIC-00.
- **Cross-service write-back atomicity is still ours to design** (D-12): PowerSync's queue is one
  `uploadData` batch, but our write-back **fans out to multiple owning-service APIs** (ownership rule
  1 — no cross-schema transaction). The engine does **not** solve this — saga/coordinator is a #106
  decision. (SP-1's prototype used single-service atomicity only.)
- **iOS PWA storage durability** (Safari evicts OPFS/IndexedDB for unused PWAs) is a general browser
  risk, not engine-specific; iOS is last in D-10. Mitigate with persistent-storage requests / native
  wrapper later.
- **Source-available (FSL), not OSI-open** until the 2-year conversion — acceptable for self-hosting
  our own product; flagged so it's a conscious choice.

## Alternatives considered

- **ElectricSQL (electric-next).** Rejected for v1: offline **writes, client persistence, and conflict
  handling are out of scope** (we'd hand-build the entire offline write/queue/conflict stack) and there
  is **no official Flutter client** — a poor fit for an offline-first Flutter app. Strong for read-heavy
  live-query sync, which is not our primary need.
- **Roll our own sync** (change-feed + queue + reconciliation over our REST APIs). Maximum control and
  no new dependency, but re-implements exactly what PowerSync provides (durable queue, checkpoints,
  partial replication, client SQLite) — high cost/risk for a small team. Rejected; revisitable if
  PowerSync's operational cost proves too high.
- **PowerSync Cloud (managed).** Rejected for v1: org data must stay on our self-hosted, EU-resident
  infra (NFR-CMP); Open Edition self-host meets that. Managed remains a fallback.

## Follow-ups

- **#106 — ✅ delivered** in [sync.md](../architecture/sync.md) / [ADR-0006](0006-sync-conflict-resolution.md):
  org-scoped Sync Rules (the client slice), the sync-publication contract each service honors, the
  **cross-service write-back atomicity mechanism** (D-12 → single-endpoint seam + validate-first /
  forward-retry), client↔server validation parity, tombstones/deletes, and the "synced" status +
  notify-and-fix UX (FR-OF-2).
- **EPIC-13 (#22) — ✅ subchart delivered**: `infra/helm/beekeepingit/charts/powersync/` — the
  self-hosted service + a **Postgres** storage backend (not MongoDB, matching the SP-1 config
  below — avoids a second datastore technology). Ships with two documented local-dev stopgaps
  (placeholder sync-config, Keycloak-realm JWKS) since no domain tables/connector exist yet —
  see `FOLLOWUPS.md`.
- **EPIC-06 (#7) / EPIC-00 (#1) — still open**: the per-service connector in the shared service
  template, the real org-scoped Sync Rules (once `#23` lands `apiaries`/`organizations`), and
  offline/sync tests (NFR-TST). Validate **iOS PWA** persistence when iOS is in scope (D-10).
- The SP-1 throwaway prototype (kind + Postgres + PowerSync + a Playwright-driven `@powersync/web`
  PWA) is **not committed** (research only); its config + results are captured in the
  [SP-1 report](../spikes/sp-1-powersync-vs-electricsql.md) for reproduction.
