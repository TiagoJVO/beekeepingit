# 0006 — Sync conflict resolution & cross-service write-back atomicity

- **Status:** Accepted
- **Date:** 2026-07-03
- **Issue / Epic:** #106 / #103 (EPIC-DESIGN) · builds on #54 (SP-1), #104, #105 · **Milestone:** M0
- **Requirements:** FR-OF-1, FR-OF-2, FR-HIS-1, FR-TEN-2, NFR-ARC-1, NFR-ARC-3, NFR-TST-1
- **Decisions:** [D-6](../../requirements/decisions.md#d-6--data--offline-sync-postgresql--postgis-sqlite-on-device-managed-sync) (sync),
  [D-12](../../requirements/decisions.md#d-12--offline-sync-write-back-atomic-validation-parity-notify-and-fix) (write-back integrity),
  [D-11](../../requirements/decisions.md) (AI writes via owner)
- **Questions:** **resolves [Q-SYNC](../../requirements/decisions.md)** (conflict policy + write-back mechanism) — now removed from open-questions
- **Design:** [sync.md](../architecture/sync.md) (full spec) · **Engine:** [ADR-0005](0005-sync-engine-choice.md) (PowerSync)

## Context

[ADR-0005](0005-sync-engine-choice.md) chose **PowerSync** (self-hosted) and confirmed the
default conflict policy end-to-end in [SP-1](../spikes/sp-1-powersync-vs-electricsql.md), but
explicitly handed **#106** the parts the engine does not solve: the **org-scoped client slice**,
the **sync-publication contract**, tombstones/validation-parity, and — the hard one — the
**cross-service write-back atomicity mechanism** ([D-12](../../requirements/decisions.md#d-12--offline-sync-write-back-atomic-validation-parity-notify-and-fix)).

Two constraints shape the decision:

- **D-12 wants an atomic push** (reject one change → the whole push rolls back), but **ownership
  rule 1** ([service-decomposition.md](../architecture/service-decomposition.md) §4) **forbids a
  single DB transaction across schemas.** A multi-service push cannot be one transaction.
- The concern is **offline-deferred pushes only**; online writes conflict at the DB normally. Two
  users editing the *same* record in overlapping *offline* windows is **rare**. And PowerSync's
  write model means the **client must reconcile rejected/superseded writes regardless** (its
  checkpoint reverts un-applied local changes), so **client-side conflict handling is a fixed cost
  in every option** — it does not distinguish them.

The brief was therefore: pick the **cheapest viable v1 mechanism that does not foreclose a
stronger one later**.

## Decision

### 1. Conflict policy — server-authoritative, record-level LWW + conflict log

The **owning service** is authoritative. On write-back it applies a row only if the incoming
device `updated_at` is **strictly newer** than the stored value; otherwise it keeps the server
value and writes the loser to **`sync_conflict_log`** (non-destructive — nothing is silently
lost, and the log doubles as telemetry). Clock source is the **device wall-clock `updated_at`**
for v1 (HLC is a later comparator swap). Deletes are **soft-delete tombstones** that participate
in LWW. **Field-level merge is deferred** — record-level LWW plus the log for v1; add per-field
merge only where the conflict log shows it hurts. Full spec: [sync.md](../architecture/sync.md) §4.

### 2. Write-back atomicity — a single server-side seam, with "A-lite" behind it

**The client always POSTs the whole client transaction to ONE server-side write-back endpoint.**
This **seam** is the primary decision: the *apply mechanism* lives entirely behind it and is
swappable with **zero client change**.

Behind the seam, v1 uses **"A-lite": validate-first + idempotent forward-retry** —

1. **validate-all** across every involved service *before any write* (dovetails with client-side
   validation parity, so most rejections never leave the device);
2. **apply** each service's batch in **its own local transaction** (LWW + conflict log + history);
3. on a **post-validation transient failure**, PowerSync's normal batch retry **rolls forward to
   completion** (ops are idempotent on the client UUID PK) — no compensation code.

Each owning service honors the **sync-publication contract** ([sync.md](../architecture/sync.md)
§5): replicable table shape (down) + an idempotent, validating, history-recording, **prior-state-
capturing** sync-apply endpoint (up). The coordinator is a thin **stateless** component that owns
no data and holds no cross-schema write credentials.

**Compensation / true cross-service rollback is specified but not built** — prior-state capture
keeps it (or any stronger option) a later change behind the seam.

## Consequences

**Positive**
- **Honors D-12 for the real traffic:** single-service pushes are trivially atomic; multi-service
  pushes get validate-first (rejects touch nothing) + forward-retry (transient faults heal) — no
  partial *incorrect* state, which is D-12's intent.
- **Least v1 code:** no saga engine, no compensation, no 2PC — just per-service local transactions
  behind one endpoint.
- **Most future-proof:** the seam lets us add field-merge, compensation, HLC, 2PC, or a workflow
  engine later **without touching three client platforms**. Nothing here blocks the stronger
  options — the explicit constraint the design was held to.
- **Thin client + one field round-trip:** the offline device just posts one batch; fan-out is fast
  in-cluster — better on poor connectivity than N client calls.
- **Preserves ownership** (rule 1) and the AI write-safety guarantee (D-11): every write goes
  through the owning service's validated, audited API; the coordinator writes nothing directly.
- **Non-destructive conflicts:** the conflict log retains losers and is the signal for when to
  invest further.

**Negative / risks**
- **A new (if thin) coordinator component** to build and operate (mitigated: stateless, may begin
  as a gateway/BFF route).
- **A-lite does not undo a "validated-then-permanently-rejected" op** — accepted because
  validation is the gate; if this case ever appears, compensation is the specified next step.
- **Record-level LWW can lose a concurrent edit to a *different field*** — accepted for v1
  (rare, logged, recoverable); field-merge is the documented upgrade.
- **Device clock skew** can mis-order rare concurrent offline edits — recoverable via the log;
  HLC is the upgrade.

## Alternatives considered

- **Client-side fan-out (no coordinator).** The device routes each op to its owning service.
  **Rejected:** it either drops cross-service atomicity or pushes compensation onto the device,
  and it **bakes routing + partial-failure handling into three client platforms** — the one option
  that *soft-blocks* the future (migrating to a coordinator later means re-doing client sync logic).
  Since client conflict-handling is a fixed cost anyway, it saves little. This is *why* the seam is
  server-side.
- **2PC / Postgres prepared transactions.** True cross-service ACID. **Rejected for v1:** holds
  locks across the multi-service round-trip, and a coordinator crash between prepare and commit
  leaves **in-doubt prepared transactions** pinning locks/slots and blocking vacuum until resolved
  — an operational trap for a small self-hosted team, for a rare case. Reachable behind the seam.
- **Choreographed (event/outbox) saga.** Ingest accepts the push; services react via events.
  **Rejected for v1:** async apply fights PowerSync's expectation of a **synchronous** accept/reject
  at push time (needed for notify-and-fix), adds an event bus + relay + consumers, and overlaps the
  #107 history/outbox work. Revisitable if write-back grows genuinely long-running.
- **Orchestrated saga on a durable workflow engine (Temporal-style).** Robust orchestration +
  compensation. **Rejected for v1:** real infrastructure to run for traffic that is mostly
  single-service; A-lite is the same shape (orchestration) minus the engine, and the seam lets us
  adopt it later if compensation becomes routine.
- **No atomicity (per-op best-effort).** **Rejected:** violates D-12's atomic-push requirement.

## Follow-ups

- **EPIC-06 (#7)** — build the coordinator + per-service sync-apply endpoints, the notify-and-fix
  screens, and the validation-parity mechanism; PowerSync subchart + connector (with EPIC-13);
  offline/sync + boundary contract tests (NFR-TST).
- **#107** — history capture mechanism (events/outbox/triggers) feeding `audit_log`; Q-HIS
  retention.
- Add **field-level merge** / **compensation** / **HLC** *iff* the conflict log or operations show
  they are needed — all reachable behind the seam.
