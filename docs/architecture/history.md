# History / Audit Architecture

> **Status:** High-Level Design (HLD) for v1 — the target the M0 build realizes; refined toward
> as-built as history capture lands (EPIC-07 #8). Builds on
> [service-decomposition.md](service-decomposition.md), [data-model.md](data-model.md) and
> [sync.md](sync.md). Intent lives in [../../requirements/](../../requirements/).

**Issue:** #107 · **Epic:** #103 (EPIC-DESIGN) · **Milestone:** M0
**Requirements:** FR-HIS-1, FR-TEN-2, NFR-CMP-1, NFR-ARC-1
**Decisions:** [D-6](../../requirements/decisions.md#d-6--data--offline-sync-postgresql--postgis-sqlite-on-device-managed-sync) (schema-per-service, sync),
[D-11](../../requirements/decisions.md#d-11--ai-write-actions-propose--confirm--owner-executes) (AI writes via owner), [D-1](../../requirements/decisions.md) (microservices)
**Questions:** **resolves [Q-HIS](../../requirements/open-questions.md)** (retention, immutability,
visibility, offline behaviour) — now removed from open-questions; this doc + [ADR-0007](../adr/0007-history-audit.md) are its place of record
**Depends on:** #105 (data model), #106 (sync) · **ADR:** [0007-history-audit](../adr/0007-history-audit.md)

---

## 1. Scope

The **append-only change history** (FR-HIS-1) for every entity: who changed what, when, and how,
kept correct across **offline edits + sync** (#106). Concretely this document decides the five
things #107 owes:

1. the **append-only, per-entity history model** — actor + timestamps + change (§3);
2. the **capture mechanism** — synchronous, in-transaction, per owning service (§4);
3. the **storage placement** — per-service vs central, decided with trade-offs (§5);
4. how history **survives offline + sync**, incl. the interaction with the #106 conflict policy (§6);
5. the **retention / immutability / visibility** stance (§7–§8), resolving [Q-HIS](../../requirements/open-questions.md).

The **build is EPIC-07** (#8); this doc fixes the shapes and rules that build realizes. It refines
the `audit_log` shape reserved in [data-model.md](data-model.md) §3 and finalizes the "mechanism
#107" that [sync.md](sync.md) §5.2/§7 defers to here.

---

## 2. Mental model — history is a side-effect of the write, in the same transaction

```
   owning service (e.g. apiaries)
   ┌───────────────────────────────────────────────────────────────┐
   │  write path (ONE local transaction)                            │
   │    1. validate + authorize + org-scope                         │
   │    2. UPSERT domain row        ── apiaries                     │
   │    3. INSERT audit row         ── apiaries.audit_log (append)  │
   │    COMMIT  ── domain change and its history commit together    │
   └───────────────────────────────────────────────────────────────┘
        ▲                                   ▲
        │ online API write                  │ offline write replayed via
        │ (normal request)                  │ the sync-apply endpoint (sync §5.2)
        └───────────────────────────────────┘
              same code path → history recorded identically either way
```

History is **not** a separate subsystem the write has to reach. Each owning service appends its
audit row **in the same local transaction** as the domain mutation, on **both** the online write
path and the offline **sync-apply** path ([sync.md](sync.md) §5.2). The history row therefore
commits **iff** the change commits — it can never be lost, backdated, or drift from the data.

---

## 3. The history model (append-only, per entity)

One immutable row per change, polymorphic over every entity by (`entity_type`, `entity_id`). This
finalizes the `AUDIT_LOG` shape from [data-model.md](data-model.md) §3.

| Column | Type | Meaning |
|---|---|---|
| `id` | `uuid` (v7) PK | client/server-generatable; time-ordered |
| `organization_id` | `uuid` | tenancy key — every audit row is org-scoped (FR-TEN, RLS, sync slice) |
| `entity_type` | `text` | `apiary` \| `activity` \| `journey` \| `todo` \| `membership` \| … (open set) |
| `entity_id` | `uuid` | soft reference to the changed row (no cross-schema FK) |
| `change_type` | `text` | `create` \| `update` \| `delete` (soft-delete tombstone, §6) |
| `actor_user_id` | `uuid` | **internal user UUID only** — soft ref to `identity.users`; **never** denormalized actor PII (§7.3) |
| `occurred_at` | `timestamptz` | **device** time the change was made (offline-correct, §6) |
| `recorded_at` | `timestamptz` | **server** time the change was applied/committed |
| `snapshot` | `jsonb` | post-change state of the row (soft ID refs, no embedded personal data, §7.3) |
| `changed_fields` | `text[]` (optional) | on `update`, the columns that changed — cheap diff for the timeline UI |

**Notes**

- **Actor is an opaque internal ID.** The audit row records *that user `<uuid>` changed it*, never
  their name/email. Personal data is resolved by **join** to `identity.users` at display time
  (§7.3, §8) — the design property that removes the GDPR-erasure clash.
- **Two clocks.** `occurred_at` (device) vs `recorded_at` (server) mirror
  [data-model.md](data-model.md) §2's device-time-vs-server-time split, so a change made offline
  Monday and synced Wednesday reads *occurred Monday, recorded Wednesday* — not backdated or lost.
- **Prior state for `update`** need not be duplicated: [sync.md](sync.md) §5.2 already requires the
  apply step to **capture prior state** (for reversibility); the timeline computes a diff from the
  previous audit row's `snapshot` (or `changed_fields`), so we store the **post-change** snapshot only.

---

## 4. Capture mechanism — synchronous, in-transaction, per owning service

**Decision:** each owning service writes its own audit row **synchronously, inside the same local
transaction** as the domain mutation — on both the online write path and the sync-apply path
([sync.md](sync.md) §5.2). No triggers, no CDC, no event bus, no outbox in v1.

**Why in-transaction (not async):**

- **Atomicity = correctness.** History commits with the change or not at all. There is no window
  where a change exists without its history, and no relay/consumer that could lag or drop events.
- **One path for online and offline.** The sync-apply endpoint is *the same service write path*;
  recording history there means offline-then-synced edits are audited **identically** to online
  ones, with the device `occurred_at` preserved (§6). Nothing special is needed for the sync case.
- **Least v1 infra.** It reuses the local transaction each service already opens; it does **not**
  pull in the event-bus/outbox machinery that [ADR-0006](../adr/0006-sync-conflict-resolution.md)
  explicitly **deferred** ("overlaps the #107 history/outbox work").

**Rejected for v1** (full weighing in [ADR-0007](../adr/0007-history-audit.md)): DB **triggers**
(hidden control flow, harder to test/version, can't see the app-level actor cleanly),
**CDC/logical-decoding** into a history service (async, extra infra, eventual), **transactional
outbox → events → central projection** (async + new infra; the reserved *upgrade*, not v1, §5),
and **app-level after-commit write** (a second transaction that can fail independently — reopens
the lost-history window).

**Idempotency.** The sync-apply step is idempotent on the client UUID PK ([sync.md](sync.md) §5.2 /
§6.2 forward-retry). Because the audit INSERT lives **inside** that same idempotent apply, a
replayed/forward-retried op that no-ops the domain write also writes **no** new audit row — history
is not double-counted on retry.

---

## 5. Storage placement — per-service, co-located (the #107 storage decision)

**Decision:** history is **per-service** — each owning service holds its own append-only
`audit_log` table **inside its own schema** (`apiaries.audit_log`, `activities.audit_log`, …).
There is **no** central `history` schema/service written to synchronously by everyone.

**Why (this is forced by ownership + the in-transaction choice):**

- **Ownership rule 1** ([service-decomposition.md](service-decomposition.md) §4: *a service writes
  only its own schema*) **forbids** a central history schema written synchronously by every
  service — that would be a cross-schema write. Keeping the audit INSERT in the domain write's
  local transaction (§4) therefore **requires** the audit table to live in the **same schema**.
- **The FR-HIS view is per-entity.** "View the history of *this* apiary / activity / journey"
  (FR-HIS-1, §8) is answered entirely by the **owning service's own** `audit_log` — no cross-schema
  join (ownership rule 3), no fan-out.

**Trade-offs considered**

| Option | Atomic w/ write | Honors ownership | Per-entity view | Global timeline | v1 infra | Verdict |
|---|---|---|---|---|---|---|
| **Per-service, in-tx `audit_log`** (chosen) | ✅ same local tx | ✅ own schema only | ✅ owning service | ⚠️ needs fan-out/projection | none | **v1** |
| Central `history` schema, **sync** write | ✅ | ❌ cross-schema write | ✅ | ✅ single table | none | **rejected** — breaks rule 1 |
| Central `history` schema, **async** (outbox→events→projection) | ❌ eventual | ✅ (services write own outbox) | ✅ | ✅ | event bus + relay + consumer | **deferred upgrade** (§5.1) |
| One shared audit table, all services write | ✅ | ❌ shared ownership | ✅ | ✅ | none | **rejected** — ownership ambiguity (D-1/AC) |

### 5.1 Reserved upgrade — a global cross-entity timeline behind the boundary

A **cross-entity / org-wide** audit feed (e.g. an admin "everything that changed today" view) is
**not** an FR-HIS-1 requirement and is **not built in v1**. When it is wanted, it is added
**without changing how services record history**: each service emits its already-captured audit
rows via a **transactional outbox**, and a **history read-projection** consumes them into a single
queryable timeline — a projection **behind the service boundary**, the same seam-preserving pattern
[sync.md](sync.md) §6 uses for write-back. Until then, cross-entity history is **API composition**
over the per-service logs (ownership rule 3), which is sufficient for v1.

---

## 6. Survives offline edits + sync (interaction with the #106 conflict policy)

History is designed against the [sync.md](sync.md) reconciliation flow, not bolted on after:

- **Recorded on the apply path.** Every applied create/update/delete — whether written online or
  replayed from an offline queue — records history in the same transaction (§4), stamping
  `occurred_at` = device time and `recorded_at` = server time ([sync.md](sync.md) §7). Late sync is
  therefore **correct, not backdated**.
- **Recent history is offline-viewable.** A recent window of `audit_log` **replicates down
  read-only** in the org slice ([sync.md](sync.md) §3.2), so the entity's history view works
  **offline** for recent changes. **Deep history is an online query** against the owning service —
  the field client does not carry unbounded history.
- **LWW losers are not lost.** The #106 policy is **record-level last-write-wins + a conflict log**.
  A losing offline edit is preserved in **`sync_conflict_log`** ([sync.md](sync.md) §4.2), captured
  the **same way** as `audit_log` — per-service, in the apply transaction. The entity timeline can
  therefore surface a **`superseded`** event ("your offline change to *Serra Norte* was superseded
  by a newer value") alongside the applied changes, so no edit silently vanishes from the record.
- **Deletes are tombstones.** A soft-delete (`deleted_at`) is a `change_type = delete` audit row and
  participates in LWW like any update ([sync.md](sync.md) §4.5). Physical purge of tombstones is a
  retention concern (§7.2).

`sync_conflict_log` is the conflict-specific sibling of `audit_log`: same per-service placement,
same in-transaction capture, and it is the shape [sync.md](sync.md) §4.2 left "aligns with #107" —
now fixed here.

---

## 7. Immutability & retention (resolves Q-HIS)

### 7.1 Immutability — append-only, DB-enforced

`audit_log` is **append-only**: `INSERT`-only, never `UPDATE`/`DELETE` from the application.

- **Enforced at the database, not just in code:** the owning service's **runtime DB role is granted
  `INSERT` (and `SELECT`) but not `UPDATE`/`DELETE`** on its `audit_log` (and `sync_conflict_log`).
  A code path that tries to mutate history fails at the database — defense-in-depth, the same
  philosophy as the optional RLS backstop in [data-model.md](data-model.md) §5.
- **Corrections are new rows**, never edits — the record of "what the system believed and when"
  stays intact.
- Purge for retention (§7.2) is a **separate, privileged** maintenance role, not the service role.

### 7.2 Retention — retain in v1, purge policy deferred

- **v1 retains history indefinitely** (it is immutable and small relative to domain data). No
  automatic purge ships in v1.
- A **configurable retention window** and **legal-hold** semantics are **deferred to the compliance
  epic (EPIC-14 #15)**; nothing in this design blocks adding a purge job later (it operates via the
  privileged role of §7.1). Tombstone/soft-delete physical purge is the same concern.

### 7.3 GDPR / right-to-erasure — pseudonymous by construction (NFR-CMP)

There is **no clash** between immutable history and the GDPR right-to-erasure, because the audit log
never stores personal data in the first place:

- **`audit_log` holds only opaque internal identifiers** — `actor_user_id` (internal user UUID),
  `entity_id`, `organization_id` — and domain snapshots that themselves carry **soft ID references**,
  **never** denormalized names/emails. It is **pseudonymous by construction**.
- **Personal data lives in exactly one place:** `identity.users`. Actor and subject names are
  resolved by **join** to that table **at display time** (§8), from the org roster slice
  ([sync.md](sync.md) §3.2).
- **Erasure / unregister** operates on `identity.users` — the person's PII is deleted/scrubbed
  there. The audit rows **keep the opaque internal ID with no link back to a person**, so:
  - **audit integrity is preserved** (immutable, append-only, nothing rewritten), **and**
  - **no personal data remains** in history — the internal ID no longer resolves to anyone.

  This is crypto/pseudonymization-by-design rather than deletion of audit rows, and it is what lets
  history be simultaneously **immutable** and **GDPR-compliant**.
- **Design constraint this imposes:** snapshots and audit rows MUST NOT embed actor/member personal
  data — only soft ID references. Services build audit rows from IDs, not denormalized profiles.
  (This is a boundary/contract test target, NFR-TST.)

---

## 8. Visibility — a per-entity timeline on the entity's screen

- **Where:** history is surfaced as a **per-entity timeline on that entity's detail screen** — e.g.
  *Apiary details → history*, and likewise for activities and journeys (the FR-HIS-1 "view the
  history" feature). It is not a separate global console in v1 (§5.1).
- **Who:** **any organization member who can already access the entity** may view its history —
  consistent with **FR-TEN-2** (members share all of the org's data). No admin-only gate is added in
  v1; history visibility follows the entity's own access, adding no new authz surface. (An
  admin-scoped global feed can come with the §5.1 projection if ever needed.)
- **Actor names** shown in the timeline are resolved by joining `actor_user_id` to the org **roster
  slice** already on the device ([sync.md](sync.md) §3.2), so recent history renders offline; a
  since-erased actor simply shows as unknown/removed (§7.3).
- The concrete screens (diff rendering, EN/PT strings, WCAG 2.2 AA, gloves-friendly) belong to the
  entity EPICs (EPIC-02/03/04) and the history build (EPIC-07 #8); this doc fixes the data + rules
  they render.

---

## 9. Entity coverage

FR-HIS-1 is **all entities**. In v1 that is:

| Entity | Owning service | History source |
|---|---|---|
| `apiaries` | apiaries | `apiaries.audit_log` |
| `activities` | activities | `activities.audit_log` |
| `journeys`, `journey_plan_items`, `journey_activities` | journeys | `journeys.audit_log` |
| `todos` | todos | `todos.audit_log` |
| `memberships`, `organizations`, `invitations` | organizations | `organizations.audit_log` (admin actions) |

`identity.users` records only minimal self-profile changes; it is global (not org-owned) and carries
no `organization_id`. The `ai` service **records no domain history** — a confirmed AI action executes
through the **owning** service's API and is audited there like any edit (D-11 / ownership rule 5),
so the AI write-safety guarantee and the audit trail reinforce each other.

---

## 10. Open items, deferred scope & hand-offs

| Item | Status | Where |
|---|---|---|
| Global / cross-entity audit timeline (outbox → projection) | **Reserved, not built** — API composition suffices for v1; projection behind the boundary later (§5.1) | future; EPIC-07 if needed |
| Configurable retention window / automatic purge / legal-hold | **Deferred** — v1 retains indefinitely (§7.2) | EPIC-14 (#15) |
| Diff / `changed_fields` presentation in the timeline | **Design hand-off** — shape fixed here (§3) | EPIC-07 (#8), entity EPICs |
| Build: in-tx audit append on each service write + sync-apply path; INSERT-only grant; append-only + pseudonymity contract tests | **Depends-on** | EPIC-07 (#8), per-service EPIC-02/03/04/05 |
| History view screens (per-entity timeline, EN/PT, a11y) | **Design hand-off** — data + states fixed here | EPIC-02/03/04, EPIC-07 (#8) |
| `sync_conflict_log` surfaced as `superseded` timeline events | Shape fixed here (§6) | EPIC-06 (#7) / EPIC-07 (#8) |

---

## 11. Acceptance-criteria traceability (#107)

- [x] **Append-only, per-entity history model** (actor + timestamp + change) designed — §3
- [x] **History survives offline edits + sync**; interaction with the #106 conflict policy specified
  (recorded on the apply path, recent-history offline slice, LWW losers via `sync_conflict_log`) — §6
- [x] **Storage approach** (per-schema vs central) decided **with trade-offs** — per-service,
  co-located, in-transaction; central-async reserved as an upgrade — §5
- [x] **Retention / immutability stance noted** — append-only + DB-enforced immutability; retain in
  v1, purge deferred; **GDPR resolved** by pseudonymity-by-construction — §7
- [x] **Design + ADR in `docs/`**, resolving Q-HIS — this doc + [ADR-0007](../adr/0007-history-audit.md)

## 12. Links

- This decision: [ADR-0007](../adr/0007-history-audit.md)
- Builds on: [service-decomposition.md](service-decomposition.md) (#104) ·
  [data-model.md](data-model.md) (#105) · [sync.md](sync.md) (#106) ·
  [auth.md](auth.md) (#109, actor identity)
- Intent: [functional-requirements.md](../../requirements/functional-requirements.md) (FR-HIS-1) ·
  [decisions.md](../../requirements/decisions.md) (D-6, D-11) — resolves
  [Q-HIS](../../requirements/open-questions.md)
- Build: **EPIC-07 — History & Audit (#8)**
- Last in EPIC-DESIGN's data/sync chain: #105 → #106 → **#107** → #108 (contracts) / #110 (skeleton)
