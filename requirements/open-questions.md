# Open Questions & Requirements Gaps

Genuinely **unresolved** questions to settle, ordered by how much they reshape the
plan. Each references the `FR-*/NFR-*` it affects and offers a **recommended default**
where there's a sensible one.

> **This file holds only open (or explicitly deferred) questions.** When a question is
> **answered it is removed from here**, and its answer is written to its place of record —
> a decision (`D-*`) in [decisions.md](decisions.md), an `FR-*/NFR-*`, or `docs/` — with
> that artifact citing the `Q-*` ID so traceability survives the removal. See the
> **`open-questions` skill** ([`.claude/skills/open-questions`](../.claude/skills/open-questions/SKILL.md))
> for the full read / add / resolve workflow.

---

## Tier 1 — Foundational (these reshape the whole plan)

### Q-SYNC — Offline sync: conflict resolution + write-back integrity
> **Partially addressed:** sync **engine** chosen (D-6: PowerSync/ElectricSQL — final
> pick + web/PWA persistence via **SP-1**); **write-back integrity decided** (D-12: atomic
> push, client validation parity, notify-and-fix). The **conflict policy** and the
> **atomicity mechanism** below are still to be designed.
- **Affects:** FR-OF-1, FR-OF-2, and indirectly every entity (FR-HIS-1 too).
- **Gap:** Offline + multiple users in one org editing shared data = guaranteed
  conflicts, but no resolution strategy is defined.
- **Decisions needed:** sync granularity (record vs. field), conflict policy
  (last-write-wins, per-field merge, CRDT, manual resolution), tombstones for
  deletes, clock source, and what "synced" status the UI shows. **Plus (D-12):** the
  **write-back atomicity mechanism** across per-service writes — saga/compensation vs a
  per-service transactional batch + coordinator (a multi-service push can't share one DB
  transaction; tension with ownership rule 1); **client↔server validation parity** (how
  rules are shared without divergence); and the **sync-failure notify-and-fix UX** (FR-OF-2).
- **Recommended default:** per-record **last-write-wins with server timestamps**
  for v1, plus a conflict log; revisit field-level merge only where it hurts.

---

## Tier 2 — Functional gaps to close

### Q-AICLOUD — Cloud AI privacy & GDPR (now near-term per D-8)
- **Affects:** FR-AI-1, NFR-AI-1, NFR-CMP. The PWA phase sends org data to a hosted
  LLM. Needed before building the AI feature: **provider choice** (e.g. Claude API),
  a **DPA**, a **no-training** guarantee, **EU data residency**, an **explicit
  consent** UX, and **PII minimization** (what may leave the device).

### Q-JOUR — Journey planned-vs-actual model
- **Affects:** FR-JO-1, FR-JO-4. "How much is missing" needs a **plan** (intended
  apiaries/activities) compared against **executed** activities. Define how
  activities link to a journey (manual selection, or auto-match by
  apiary+type+date window).

### Q-TODO — Todo lifecycle & associations
- **Affects:** FR-TD-1, FR-AI-1. Only create + list are specified. Need: complete /
  reopen / edit / delete, assignment to a user, and association to an **apiary or
  area** (the AI example "todos pending for the area of apiary X" requires it).

### Q-DIST — Distance measurement semantics
- **Affects:** FR-AP-5. Straight-line (works offline) vs. driving distance (needs a
  routing service, online). How are the two apiaries chosen? Is distance also shown
  from the user's current location (FR-AP-2 already orders by proximity)?
- **Recommended default:** straight-line (haversine) offline; optional driving
  distance when online.

### Q-MAP — Map provider & offline tiles
- **Affects:** FR-AP-3, FR-OF-1. A field-first map that works **offline** needs
  cached map tiles. Decision: provider (Google Maps, Mapbox, OpenStreetMap/MapLibre)
  and offline-tile strategy. This has licensing and cost implications.

### Q-IMP — Import semantics
- **Affects:** FR-IE-2. Merge vs. replace, ID preservation, duplicate handling, and
  how import interacts with sync/history.

### Q-NOTIF — Notifications
- **Affects:** FR-ST-1, FR-TD-1. "Notification preferences" implies a notification
  system, but none is otherwise specified. What events (todo due, sync results),
  what channel (in-app, push), and does push require a backend service + store
  registration?

### Q-SEARCH — Search scope
- **Affects:** FR-AP-6. Offline or online? Apiaries only, or activities/journeys/
  todos too? What are the "other attributes"?

---

## Tier 3 — NFR / operational clarifications

### Q-AUTH — Authentication details, especially offline
- **Affects:** NFR-SEC-1, FR-AU-1. **Mechanism set by D-7** (Keycloak / OIDC). Still
  open: email verification, password reset, session/token lifetime, and **how login
  works when offline** (cached credentials/tokens) — critical for a field-first app.

### Q-LLM — On-device LLM feasibility — ⏭️ DEFERRED to native phase (D-8/D-10 → SP-2)
- **Affects:** NFR-AI-2/3, FR-AI-1. The PWA phase uses **cloud AI**, so on-device is
  no longer near-term. Revisit at the native phase (model, device specs, size,
  quality) via **SP-2**.

### Q-ROLE — Admin scope & capabilities
- **Affects:** NFR-ROL-1/2. Is "admin" per-organization or system-wide? Exactly
  what can admin do (manage members, roles, org settings, quotas)? Does any of this
  exist in the mobile app or only the Admin App?

### Q-CMP / Q-REG — Compliance & Portuguese regulation
- **Affects:** NFR-CMP-1, Context C-2. Confirm **GDPR** scope (data export/erasure,
  consent for cloud AI per NFR-AI-1). **HIPAA is very likely not applicable** —
  confirm and drop. Enumerate the actual **Portuguese/EU beekeeping & food
  (honey) traceability** obligations (e.g., apiary registration, treatment
  records) that may become real requirements.

### Q-DR — Backup/DR targets
- **Affects:** NFR-DR-1. RPO/RTO numbers; what is backed up (server-side org data,
  on-device data, or both); restore testing.

### Q-PERF — Concrete performance targets
- **Affects:** NFR-PER-1. Define measurable targets (screen/API latency, map with N
  markers, offline query times) so "fast" is testable.

---

## Tier 4 — Smaller clarifications

- **Q-TEN** — Confirm the tenancy interpretation: isolation is at the
  **organization** level (resolved in FR-TEN-2), not per-user as frs line 28 reads
  literally.
- **Q-HIS** — History retention period, immutability, visibility (all users or
  admin only), and behaviour across offline edits/sync.
- **Q-AX** — Accessibility target standard/level (recommend **WCAG 2.2 AA**).
- **Q-EXPORT-PII** — Export (FR-IE-1) of activities tied to users may include PII;
  confirm what's allowed under GDPR.
- **Units & formats** — confirm metric units (kg/L) and Portuguese locale defaults
  for dates/numbers (aligns with NFR-I18N-1).
