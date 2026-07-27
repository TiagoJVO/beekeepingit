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

### Q-MAP — Offline-tile caching strategy & production-traffic tile provider (narrowed, was: map provider & offline tiles)

- **Affects:** FR-AP-3, FR-OF-1. The map _interaction_ shape (markers, user location, measure
  overlay), the base library (`flutter_map` + MapLibre/OSM), and — as of #257 — which **online**
  tile sources render by default and how they're toggled/attributed (satellite/Esri World
  Imagery default, OSM streets alternative, both attributed) are **resolved** — see
  [D-16](decisions.md#d-16--map-flutter_map-markers--user-location--measure-overlay-tile-provider-deferred).
  Still open: a field-first map that works **offline** needs **cached map tiles** — which is not
  the same question as the ONLINE default decided above. Two things remain undecided: (1) the
  **production-traffic tile provider** — the public Esri/OSM demo endpoints this app uses today
  are not meant for production-scale load, so a paid/self-hosted provider decision is still
  needed before real traffic; and (2) the **offline-tile caching strategy** (what to pre-cache,
  storage budget, refresh). This has licensing and cost implications; does not block M2/M3
  (online-only map ships first).

---

## Tier 3 — NFR / operational clarifications

### Q-LLM — On-device LLM feasibility — ⏭️ DEFERRED to native phase (D-8/D-10 → SP-2)

- **Affects:** NFR-AI-2/3, FR-AI-1. The PWA phase uses **cloud AI**, so on-device is
  no longer near-term. Revisit at the native phase (model, device specs, size,
  quality) via **SP-2**.

### Q-DR — Backup/DR targets

- **Affects:** NFR-DR-1. RPO/RTO numbers; what is backed up (server-side org data,
  on-device data, or both); restore testing.

### Q-PERF — Concrete performance targets

- **Affects:** NFR-PER-1. Define measurable targets (screen/API latency, map with N
  markers, offline query times) so "fast" is testable.

---

## Tier 4 — Smaller clarifications

- **Q-EXPORT-PII** — Export (FR-IE-1) of activities tied to users may include PII;
  confirm what's allowed under GDPR.
- **Units & formats** — confirm metric units (kg/L) and Portuguese locale defaults
  for dates/numbers (aligns with NFR-I18N-1).
