# Open Questions & Requirements Gaps

Genuinely **unresolved** questions to settle, ordered by how much they reshape the
plan. Each references the `FR-*/NFR-*` it affects and offers a **recommended default**
where there's a sensible one.

> **This file holds only open (or explicitly deferred) questions.** When a question is
> **answered it is removed from here**, and its answer is written to its place of record —
> a decision (`D-*`) in [decisions.md](decisions.md), an `FR-*/NFR-*`, or `docs/` — with
> that artifact citing the `Q-*` ID so traceability survives the removal. See the
> **`requirements-folder` skill** ([`.claude/skills/requirements-folder`](../.claude/skills/requirements-folder/SKILL.md))
> for this and the other requirements/ conventions.

---

> **Tier 1 (foundational) is empty — resolved.** The former **Q-SYNC** (offline sync: conflict
> resolution + write-back integrity) is **fully resolved**: engine → PowerSync
> ([ADR-0005](../docs/adr/0005-sync-engine-choice.md), SP-1 #54); conflict policy, client slice,
> publication contract, tombstones, clock source, validation parity, notify-and-fix UX, and the
> cross-service **write-back atomicity mechanism** (D-12) are decided in
> [`docs/architecture/sync.md`](../docs/architecture/sync.md) / [ADR-0006](../docs/adr/0006-sync-conflict-resolution.md)
> (#106), which cite Q-SYNC as their origin. Field-level merge and compensation are **documented
> future refinements**, not open blockers.

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

### Q-MAP — Offline-tile caching strategy & tile provider (narrowed, was: map provider & offline tiles)

- **Affects:** FR-AP-3, FR-OF-1. The map *interaction* shape (markers, user location, measure
  overlay) and the base library (`flutter_map` + MapLibre/OSM) are **resolved** — see
  [D-16](decisions.md#d-16--map-flutter_map-markers--user-location--measure-overlay-tile-provider-deferred).
  Still open: a field-first map that works **offline** needs **cached map tiles** — which tile
  *provider* to use at production traffic (the public OSM/MapLibre demo endpoint isn't meant for
  that) and the **offline-tile caching strategy** (what to pre-cache, storage budget, refresh).
  This has licensing and cost implications; does not block M2 (online-only map ships first).

### Q-IMP — Import semantics

- **Affects:** FR-IE-2. Merge vs. replace, ID preservation, duplicate handling, and
  how import interacts with sync/history.

### Q-NOTIF — Notifications

- **Affects:** FR-ST-1, FR-TD-1. "Notification preferences" implies a notification
  system, but none is otherwise specified. What events (todo due, sync results),
  what channel (in-app, push), and does push require a backend service + store
  registration?

---

## Tier 3 — NFR / operational clarifications

### Q-LLM — On-device LLM feasibility — ⏭️ DEFERRED to native phase (D-8/D-10 → SP-2)

- **Affects:** NFR-AI-2/3, FR-AI-1. The PWA phase uses **cloud AI**, so on-device is
  no longer near-term. Revisit at the native phase (model, device specs, size,
  quality) via **SP-2**.

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
- **Q-AX** — Accessibility target standard/level (recommend **WCAG 2.2 AA**).
- **Q-EXPORT-PII** — Export (FR-IE-1) of activities tied to users may include PII;
  confirm what's allowed under GDPR.
- **Units & formats** — confirm metric units (kg/L) and Portuguese locale defaults
  for dates/numbers (aligns with NFR-I18N-1).
