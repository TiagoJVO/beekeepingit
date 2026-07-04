# 0007 — History / audit: append-only, per-service, in-transaction capture

- **Status:** Accepted
- **Date:** 2026-07-04
- **Issue / Epic:** #107 / #103 (EPIC-DESIGN) · builds on #105, #106 · **Milestone:** M0
- **Requirements:** FR-HIS-1, FR-TEN-2, NFR-CMP-1, NFR-ARC-1, NFR-TST-1
- **Decisions:** [D-6](../../requirements/decisions.md#d-6--data--offline-sync-postgresql--postgis-sqlite-on-device-managed-sync) (schema-per-service, sync),
  [D-11](../../requirements/decisions.md#d-11--ai-write-actions-propose--confirm--owner-executes) (AI writes via owner), [D-1](../../requirements/decisions.md) (microservices)
- **Questions:** **resolves [Q-HIS](../../requirements/open-questions.md)** (retention, immutability,
  visibility, offline behaviour) — now removed from open-questions
- **Design:** [history.md](../architecture/history.md) (full spec) · builds on
  [data-model.md](../architecture/data-model.md) §3 (`audit_log` shape), [sync.md](../architecture/sync.md) §5.2/§7 (apply path)

## Context

FR-HIS-1 requires a **change history for every entity** — who changed what and when, viewable per
entity — that stays correct across **offline edits + sync**. [data-model.md](../architecture/data-model.md)
§3 reserved an `audit_log` shape and [sync.md](../architecture/sync.md) §5.2/§7 record history "in
the apply transaction (mechanism #107)" but deferred the mechanism, storage placement, and the
[Q-HIS](../../requirements/open-questions.md) policy (retention, immutability, visibility) to #107.

Two constraints shape the decision:

- **Ownership rule 1** ([service-decomposition.md](../architecture/service-decomposition.md) §4): a
  service writes **only its own schema** — no cross-schema writes. So a central history schema
  written **synchronously** by every service is impossible without breaking the boundary.
- **History must not diverge from the data**, including on the offline→online path — and it must not
  reopen the event-infra work that [ADR-0006](0006-sync-conflict-resolution.md) explicitly
  **deferred** ("overlaps the #107 history/outbox work").

The brief: capture history **atomically** with the change, **honoring ownership**, with **no new
infra**, and settle Q-HIS — while keeping a global timeline reachable later.

## Decision

### 1. Capture — synchronous, in the domain write's own local transaction

Each owning service appends its `audit_log` row **inside the same local transaction** as the domain
mutation, on **both** the online write path **and** the offline **sync-apply** path
([sync.md](../architecture/sync.md) §5.2). History commits **iff** the change commits — it cannot be
lost, backdated, or drift. The audit INSERT sits inside the **idempotent** apply, so a forward-retry
that no-ops the domain write writes no duplicate history. No triggers, CDC, outbox, or event bus.

### 2. Storage — per-service `audit_log`, co-located in the owning schema

History is **per-service**: each service holds its own append-only `audit_log` (and the conflict
sibling `sync_conflict_log`) **in its own schema**. This is forced by the two decisions above — an
in-transaction write must live in the same schema as the row it audits (ownership rule 1). The
FR-HIS-1 **per-entity** view ("history of *this* apiary") is served by the owning service's own log
with **no cross-schema join** (ownership rule 3). A **central, cross-entity timeline is reserved**,
not built: added later via a **transactional outbox → history projection behind the service
boundary**, changing nothing about how services record.

### 3. Model — opaque, two-clock, append-only

`audit_log` = `{ id, organization_id, entity_type, entity_id, change_type(create|update|delete),
actor_user_id, occurred_at(device), recorded_at(server), changed_fields(text[]), change(jsonb) }`.
`change` is a **field-level delta, not a full snapshot** — `create` writes the baseline values,
`update` writes `{field:{from,to}}` for changed columns only, `delete` writes just the tombstone
marker; this keeps the table growing with **change volume, not row size** and matches what the
timeline renders. `actor_user_id` is the **internal user UUID only**; the delta carries **soft ID
references** — **never denormalized personal data**. Two clocks keep late sync correct (occurred vs
recorded).

### 4. Q-HIS — immutability, retention, GDPR, visibility

- **Immutable, DB-enforced:** the service runtime role has `INSERT`/`SELECT` but **not
  `UPDATE`/`DELETE`** on `audit_log`; corrections are new rows. Purge is a separate privileged role.
- **Retention:** **retain indefinitely in v1**; configurable window / legal-hold / purge
  **deferred to EPIC-14 (#15)**.
- **GDPR (right-to-erasure) — no clash:** history is **pseudonymous by construction**. It stores only
  opaque internal IDs; personal data lives solely in `identity.users` and is joined at display time.
  **Erasure scrubs `identity.users`**; audit rows keep the opaque ID with **no link to a person** —
  audit integrity preserved **and** no personal data retained.
- **Visibility:** a **per-entity timeline on the entity's detail screen**, visible to **any org
  member who can access the entity** (FR-TEN-2). No admin-only gate in v1.

### 5. Offline + sync

Recorded on the apply path with device/server clocks; a **recent window replicates down read-only**
for offline viewing ([sync.md](../architecture/sync.md) §3.2), deep history is an online query. #106
**LWW losers** are preserved in `sync_conflict_log` and surfaced as **`superseded`** timeline events,
so no edit silently disappears.

## Consequences

**Positive**
- **History cannot be lost or diverge** — it shares the change's transaction; no relay/consumer to lag.
- **One path for online + offline** — the sync-apply endpoint records history identically; offline
  edits are audited with their true device time.
- **Honors ownership** (rule 1/3) and the **AI write-safety guarantee** (D-11) — every write, incl.
  confirmed AI actions, is audited by the owning service.
- **Least v1 infra** — reuses each service's local transaction; no event bus/outbox/CDC.
- **Immutable *and* GDPR-compliant** — pseudonymity-by-construction resolves the erasure tension
  without deleting audit rows.
- **Future-proof** — a global timeline, retention/purge, and legal-hold are all reachable **behind
  the boundary** without changing how services capture.

**Negative / risks**
- **No single global audit table in v1** — a cross-entity feed needs API composition until the §5.1
  projection is built (accepted: not an FR-HIS-1 requirement).
- **Per-service audit tables repeat a small pattern** across services — mitigated by the shared
  service template (validation/history helper), so capture is one reused call.
- **Discipline required** that audit rows/snapshots never embed actor PII — enforced by the
  INSERT-only grant plus **pseudonymity/append-only contract tests** (NFR-TST).

## Alternatives considered

- **Central `history` schema, written synchronously by every service.** Single global table, atomic.
  **Rejected:** a cross-schema write — **breaks ownership rule 1**; a service would hold write
  credentials to another schema.
- **Central `history` schema, written asynchronously (transactional outbox → events → projection).**
  Honors ownership; gives a global timeline. **Rejected for v1:** eventual (a window where the change
  exists without history), and it needs the **event bus + relay + consumer** that
  [ADR-0006](0006-sync-conflict-resolution.md) deferred. Kept as the **reserved upgrade** (§5.1) for
  when a cross-entity feed is actually needed.
- **Database triggers write the audit row.** Guaranteed-with-the-write. **Rejected:** hidden control
  flow, harder to unit-test/version with the service, and awkward to record the **app-level actor**
  and device `occurred_at` cleanly; conflicts with the typed query layer.
- **CDC / logical decoding into a history service.** Decoupled capture. **Rejected for v1:** async,
  extra infra to run, and it double-uses the replication stream PowerSync already owns.
- **App-level after-commit write (second transaction).** Simple. **Rejected:** a separate
  transaction can fail independently — reopens the **lost-history window** the in-tx write closes.
- **One shared audit table all services write to.** Single timeline, atomic. **Rejected:** shared
  ownership — the exact cross-service data-ownership ambiguity D-1/the decomposition AC forbids.
- **Full post-change snapshot per audit row.** Self-contained rows, trivial point-in-time reads.
  **Rejected:** it grows the table with **row size × edit count** (re-copying unchanged fields) and
  duplicates the domain data; a **field-level delta** is far smaller and is exactly what the
  timeline renders. The cost — replaying baseline + deltas to materialize full past state — is not
  an FR-HIS-1 requirement (change log, not point-in-time reconstruction) and deep history is online.
- **Time-boxed retention / purge in v1.** **Rejected for v1:** unnecessary (history is immutable and
  small); deferred to EPIC-14 so v1 keeps a complete record.

## Follow-ups

- **EPIC-07 (#8)** — build in-transaction audit append on each service write **and** the sync-apply
  path; the INSERT-only grant; the per-entity history view; **append-only + pseudonymity contract
  tests** (NFR-TST); surface `sync_conflict_log` as `superseded` timeline events (with EPIC-06 #7).
- **EPIC-02/03/04/05** — each domain service records its entities' history via the shared helper and
  renders the per-entity timeline (EN/PT, WCAG 2.2 AA).
- **EPIC-14 (#15)** — retention window / automatic purge / legal-hold; GDPR-erasure runbook that
  scrubs `identity.users`.
- Build the **central history projection** (outbox → timeline) **iff** a cross-entity/global audit
  feed is needed — reachable behind the service boundary (§5.1).
