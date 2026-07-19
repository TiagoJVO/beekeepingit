# Decisions Log

Resolved decisions that supersede the corresponding open questions. Newest context
wins over earlier requirement wording.

> Decisions are the working **default, not immutable**. If contradicting one makes sense,
> propose it to the user; on confirmation, update it here (and the affected requirements).

_Last updated: 2026-07-13._

---

## D-1 — v1 uses a full microservices architecture

- **Decision:** Build **full microservices from day one** (not a modular monolith).
- **Supersedes:** Q-SCALE. Confirms NFR-ARC-1 as a **v1** requirement.
- **Note / trade-off:** This intentionally goes beyond Context C-1's "don't
  prioritize scale" — accepted for the sake of the long-term target architecture.
  Expect higher upfront cost/complexity for a single-org v1.
- **Planning implications:**
  - Service decomposition becomes a **first-class planning task** (bounded
    contexts: identity/accounts, organizations, apiaries, activities, journeys,
    todos, AI, sync, history/audit, admin — to be defined).
  - Inter-service contracts/APIs, a sync service, and cross-service data ownership
    must be designed explicitly.
  - Still targets a **single k8s cluster** initially (NFR-ARC-3).

## D-2 — Hives are a count + activity attribute, not a separate entity

- **Decision:** **No hive entities.** Apiary keeps a **hive count** (FR-AP-7), and
  relevant activities capture a **"number of hives involved"** attribute. Activities
  remain recorded at the **apiary** level.
- **Refined by D-20 (2026-07-13):** the hive **count** is still not an entity, but it now
  lives as a typed row in the `apiary_counters` 1-N child table rather than an `apiaries.hive_count`
  column (so future countables need no `apiaries`-table change). The current-state-vs-event split
  below is unchanged.
- **Supersedes:** Q-HIVE, Q-GRAN.
- **Affected requirements:**
  - **FR-AC-1** — Honey harvest gains **"number of hives harvested"**; treatment/
    feeding may optionally capture a hives-affected count.
  - **FR-JO-1** — "Hives harvested" is the **sum of the hive-count attribute**
    across harvest activities in the journey.

## D-3 — Organization membership: first user is admin, invites others by email

- **Decision:** The user who **creates an organization becomes its admin**; the
  admin **invites other members by email** to join the existing organization.
- **Supersedes:** Q-JOIN.
- **Affected requirements:** adds FR-ONB-3 / FR-TEN-3 (invitation & membership
  management). The org-creator's admin role aligns with NFR-ROL-1.
- **Still open:** invitation expiry, re-invite, removing members, transferring
  admin (minor — for planning detail).

## D-4 — v1 scope deferrals

- **Deferred out of v1** (kept only as design boundaries/stubs, built later):
  - **Billing, subscriptions & rate limits/quotas** — keep the feature-toggle and
    enforcement _mechanism_ (FR-AU-2, NFR-RL-1) but **no billing UI or quota
    enforcement** in v1; everything free.
  - **On-device/local AI** — deferred to the **native phase** (can't run in a PWA).
    The PWA phase ships **cloud AI** instead (see D-8 — this reverses the earlier
    local-only-first stance).
- **Kept in v1** (explicitly _not_ deferred):
  - **Web Admin App** (NFR-ROL-2) — in scope for v1 (role/org management).
  - **CSV/JSON import & export** (FR-IE-1/2) — in scope for v1.
- **Supersedes:** Q-SUB, Q-RL (deferred); partially Q-LLM (cloud path deferred —
  on-device model feasibility still needs a spike).

---

## Technology Stack

Core technology decisions (2026-06-27). Detail and rationale in
[tech-stack.md](tech-stack.md).

## D-5 — Stack: Flutter + Go + React

- **Client (mobile/tablet/desktop):** **Flutter (Dart)** — single codebase, strong
  offline, on-device LLM support.
- **Backend microservices:** **Go**.
- **Admin web app:** **React + TypeScript** (online-only).
- **Supersedes:** Q-STACK.

## D-6 — Data & offline sync: PostgreSQL + PostGIS, SQLite on device, managed sync

- **Backend:** **PostgreSQL + PostGIS**. For v1, microservices share **one cluster
  with a schema per service** (clean boundaries now, split later) — the agreed
  reconciliation of offline-sync vs. microservices.
- **On device:** **SQLite**.
- **Sync:** **PowerSync**, **self-hosted (Open Edition)** — engine pick **resolved by spike SP-1**
  (#54): [ADR-0005](../docs/adr/0005-sync-engine-choice.md) /
  [SP-1 report](../docs/spikes/sp-1-powersync-vs-electricsql.md). On device: **SQLite** (native) /
  wa-sqlite over OPFS/IndexedDB (web/PWA). Client writes flow through the **owning service's
  connector** (D-11/D-12), never PowerSync writing domain schemas directly.
- **Notes:** per-type activity attributes via **JSONB**; geo (proximity/distance)
  via **PostGIS**.
- **Supersedes:** Q-SYNC — **fully resolved.** Engine finalized (PowerSync); conflict policy
  (server-authoritative **record-level last-write-wins + conflict log**, validated by SP-1), the
  org-scoped client slice, the sync-publication contract, tombstones, clock source, validation
  parity, notify-and-fix UX, and the **cross-service write-back atomicity mechanism** (D-12) are
  all designed in [`docs/architecture/sync.md`](../docs/architecture/sync.md) /
  [ADR-0006](../docs/adr/0006-sync-conflict-resolution.md) (#106). Field-level merge / compensation
  are documented future refinements, not open items.

## D-7 — Identity & auth: Authentik (self-hosted), behind a provider-agnostic OIDC boundary

- **Revised 2026-07-10 (was Keycloak) — user-confirmed.** The mechanism is now
  **Authentik** (OIDC/OAuth2) on the k8s cluster, adopted behind an **IdP-agnostic
  boundary**: the app depends only on **standard OIDC** — the discovery document, JWKS,
  and standard claims — so the identity provider is a **swappable deployment detail**, not
  baked into code. Rationale + what changes: [ADR-0016](../docs/adr/0016-replace-keycloak-with-authentik.md),
  which supersedes the **Keycloak-specific** parts of [ADR-0004](../docs/adr/0004-authn-authz.md)
  and [ADR-0012](../docs/adr/0012-keycloak-minio-standalone-helmreleases.md).
- **Unchanged by the swap:** **offline token caching** for field login and the **app-level
  org-scoped authorization** layered on top (FR-TEN) — the two-layer model in
  [`docs/architecture/auth.md`](../docs/architecture/auth.md) is provider-neutral and stands
  as-is. RBAC roles (NFR-ROL) remain **app-side** (`organizations.memberships`), never IdP roles.
- **Frozen integration contract** (issuer/discovery, `sub`/`aud`, endpoints, blueprint, naming):
  [`docs/architecture/oidc-integration.md`](../docs/architecture/oidc-integration.md).
- **Supersedes:** Q-AUTH — mechanism **and** offline-login designed in `auth.md` (provider-neutral)
  - ADR-0016 (Authentik specifics).

## D-8 — AI: NL→structured-query, cloud model first (on-device later)

- **Approach (unchanged):** the assistant translates questions into a **structured
  query / tool call** over the org's data (accurate for totals, overdue todos),
  scoped to org / apiary / journey (FR-AI-1).
- **PWA phase (now): cloud model.** Run the NL→query orchestration **server-side**
  in a Go AI service that calls a **hosted LLM (e.g. the Claude API)** and queries
  Postgres. Online-only; API keys stay server-side. This **supersedes the earlier
  local-only-first stance** (D-4) — on-device LLMs can't run in a PWA.
- **Native phase (later): on-device option.** Add a **local LLM** (candidates:
  Gemma 2 2B / Llama 3.2 3B / Phi-3.5-mini via MediaPipe/llama.cpp) running the same
  NL→query pattern, plus the **local/cloud toggle** (NFR-AI-3). Feasibility via SP-2.
- **Privacy / GDPR (important):** cloud AI sends org data to an external processor →
  requires **explicit consent**, a **DPA**, a **no-training** guarantee, and
  EU-residency consideration (NFR-AI-1, NFR-CMP). Tracked as Q-AICLOUD.
- **Extended (D-11):** the assistant is **not read-only** — it can also propose
  **write actions** (user-confirmed, owner-executed). See D-11.
- **Supersedes:** Q-LLM direction; reorders NFR-AI-2/3 (cloud before local).

## D-9 — Repository structure: monorepo

- **Single monorepo** — one repository holds everything (client, backend services,
  infrastructure, docs, planning, requirements). Simpler cross-service changes, one CI
  config — fits a small team. Directories are created as work needs them, not pre-scaffolded.

## D-10 — Platform rollout: PWA → Android → iOS (native only when needed)

- **Surface priority:** **Flutter Web (installable PWA)** first → **Android** →
  **iOS**. Native build targets are added **only when a feature requires native**
  (e.g. on-device LLM, deep background sync) — not up front.
- **Why it works with Flutter:** one codebase produces the Web/PWA now and the
  native apps later, no rewrite (this is why we kept Flutter — D-5).
- **Distribution:** Web/PWA hosted + installable now; Android later via **direct
  APK** (free; ideal for a single org) or Play Store ($25 once); iOS native later
  needs the **Apple Developer Program ($99/yr)** + macOS builds.
- **Consequences:** AI is **cloud + online-only** in the PWA phase (D-8); offline
  data capture works via the sync engine's **web SDK** (iOS PWA storage persistence
  is the weak spot to validate — but iOS is last anyway).
- **Supersedes:** the earlier "native mobile app is the primary v1 surface" framing.

## D-11 — AI write-actions: propose → confirm → owner-executes

- **Decision:** the assistant is **not limited to reads**. Beyond NL→query (D-8) it can
  translate a natural-language (or **voice**) request into a **proposed structured action**
  — create/update/delete over app data (e.g. "set apiary X to 12 hives", "mark todo Y done",
  "log a 10 kg harvest at Z") — surfacing the change for the user to **confirm** (FR-AI-2).
- **Safety model (the rule):** the `ai` service holds **no direct write access** to domain
  schemas. A proposed action runs **only after explicit user confirmation** and **only through
  the owning domain service's normal API**, inheriting its validation, authz, `organization_id`
  scoping, history/audit (FR-HIS) and the offline-sync write path (D-6, #106). This **replaces**
  the blunt "AI is read-only" stance with **"AI never writes directly; writes are user-confirmed
  and owner-mediated"** (the _AI write-safety guarantee_, NFR-AI-4).
- **Why:** preserves bounded-context ownership (no service writes another's schema), keeps the
  untrusted NL/LLM **blast radius contained** (LLM output is a _proposal_, never a direct DB
  write), and **reuses** the existing validated/audited/offline write path instead of a
  privileged AI bypass. The C4 container view barely changes — `ai → pg` stays read-only and
  confirmed writes flow through the normal `client → gateway → owning service` path.
- **Scope/phase:** like all AI in the PWA phase, online-only + cloud (D-8/D-10); the confirmed
  edit then queues & syncs like any edit. **Voice input** (speech→text) is a separate input
  modality feeding the same pipeline — deferred to an **EPIC-08 spike** (cloud STT falls under
  the same Q-AICLOUD consent gate).
- **Extends:** D-8 (NL→query → NL→query **and** NL→action). Touches FR-AI-2, NFR-AI-4, NFR-CMP,
  FR-HIS, EPIC-08.

## D-12 — Offline sync write-back: atomic, validation-parity, notify-and-fix

- **Decision:** the client→server sync **push is atomic** — if any change in a push is
  rejected, the **whole push rolls back** (the server applies all-or-nothing; no partial
  write-back). The **client revalidates** queued edits against the **same rules the server
  enforces**, as closely as feasible, _before_ pushing, to catch failures locally rather than
  at the server. The **server stays authoritative** — client validation is a UX optimization,
  not a security boundary.
- **On failure:** the **pushing user is notified**, the rejected push is surfaced with the
  offending change(s), and the user **fixes it on the client** before the next push (FR-OF-2).
  The **failure-handling UX must be designed** (#106 / EPIC-06).
- **Mechanism (resolved in #106):** atomic write-back **conflicts with ownership rule 1** (no
  cross-schema transactions), so a multi-service push cannot be one DB transaction. Chosen: a
  **single server-side write-back endpoint (seam)** with **validate-first + idempotent
  forward-retry** ("A-lite") behind it — per-service local transactions, no compensation code in
  v1. Client-side fan-out, 2PC/prepared-transactions, choreographed saga, and a workflow-engine
  saga are **rejected for v1** but reachable behind the seam. Compensation/true rollback and
  field-level merge are **specified-but-deferred**. See
  [`docs/architecture/sync.md`](../docs/architecture/sync.md) §6 /
  [ADR-0006](../docs/adr/0006-sync-conflict-resolution.md).
- **Refines:** D-6 (sync) and ownership rule 1 (service-decomposition §4). Touches FR-OF-2,
  Q-SYNC, FR-HIS, EPIC-06, #106.

## D-13 — GitOps: Flux, hand-wired (not `flux bootstrap`)

- **Decision:** **Flux** is the GitOps controller (resolves the "ArgoCD/Flux optional" note in
  `tech-stack.md`) — it was already installed and trialled on the dev cluster, so adopting it is
  the path of least resistance over evaluating ArgoCD from scratch.
- **Wiring:** the Flux `GitRepository`/`Kustomization`/`HelmRelease` objects are **hand-written
  and committed like any other change** (branch → PR → squash-merge), then applied once with
  `kubectl apply -f infra/gitops/clusters/dev/` to bootstrap — **not** `flux bootstrap github`,
  which would push a deploy-key-backed commit directly to `main`, bypassing the PR-only workflow
  (`CONTRIBUTING.md`). After the one-time apply, the GitOps manifests are self-managed by Flux.
- **Reconciliation is polling-only** (`GitRepository` interval, no GitHub webhook receiver) — the
  local cluster has no public endpoint for GitHub to call.
- **Note (D-27/ADR-0018):** the GitOps manifests have since moved out of this repo into the
  separate [`beekeepingit-gitops`](https://github.com/TiagoJVO/beekeepingit-gitops) repo; the
  hand-wired, PR-only principle above is unchanged.
- See [ADR-0009](../docs/adr/0009-gitops-flux.md). Touches `NFR-ARC-3`, `NFR-MNT-1`, `#86`.

## D-14 — Delivery model: per-feature milestones + cross-cutting streams

- **Decision:** Milestones are **thin, incremental, per-feature delivery slices**, each independently
  pickable: **M0** Walking Skeleton (done) → **M1** Identity & Onboarding (done) → **M2** Apiaries (done) →
  **M3** Activities → **M4** Journeys ∥ **M5** Todos → **M6** Export → **M7** Admin App →
  **M8** AI Assistant → **M9** Settings & Notifications → **M10** Android → **M11** iOS & on-device AI →
  **M12** Import (Apiaries — deferred to the end of the rollout, D-25).
  - **Revised 2026-07-16 (D-25):** M6 was "Import/Export"; Import is split out into its own
    milestone (**M12**), scheduled last, and narrowed to apiaries-only. M6 keeps Export
    (apiaries + activities + journeys, unchanged scope).
- **Streams:** the cross-cutting concerns — **offline/sync (EPIC-06)**, **history/audit (EPIC-07)**,
  **i18n/a11y (EPIC-11)**, **security/compliance/DR (EPIC-14)**, **platform rollout (EPIC-15)** — are
  **continuous streams, not milestones**: their epics carry **no milestone** (labeled **`stream`**) and
  their sub-issues take the **milestone of first need**. Feature epics keep their first milestone.
- **Dependencies at leaf level:** sequencing is between **stories**, not epic→epic — a whole-epic
  `blocked-by` over-constrains and is what made the board look tangled.
- **Why:** the earlier flat **M0–M5** conflated capability-grouping (epics) with time-ordering
  (milestones). Spanning epics pinned to M0 and epic-level edges left milestones non-incremental — a
  single true backward edge (`#16 ◂ #9`, an M0 epic blocked by an M3 epic) plus several whole-epic
  gates. Splitting the two axes makes each milestone buildable on its own.
- **Scope gating:** a feature milestone's **story-level** scope is finalized only when its open `Q-*`
  resolves — `Q-MAP`/`Q-DIST`/`Q-SEARCH` → M2 (`Q-DIST`/`Q-SEARCH` resolved, `Q-MAP` narrowed-open).
  `Q-JOUR` → M4, `Q-TODO` → M5, `Q-IMP` → M12, `Q-AICLOUD` → M8, `Q-NOTIF` → M9 are now all
  **resolved** — see D-21 (Q-JOUR), D-23 (Q-TODO), D-25 (Q-IMP), D-22 (Q-AICLOUD), D-24 (Q-NOTIF).
- **Keeps:** the **D-10** rollout order (PWA → Android → iOS) and **D-4** deferrals (billing/quotas
  EPIC-90/91 stay milestone-less) unchanged — this only re-slices _how_ the work is bucketed.
- **Refines:** the flat-milestone framing and the `backlog-management` skill (streams are now a
  first-class kind). Touches D-4, D-10, EPIC-06/07/11/14/15. Applied to GitHub Issues 2026-07-11.

- **Recommended build phasing (added 2026-07-16, from the story-level dependency graph):** the
  milestone numbering is a naming order, not a strict build order — the story-level `blocked-by`
  graph (itself a product of this same 2026-07-16 backlog reorg) supports real parallelism. The
  actual buildable sequence:
  - **Phase 1 (start immediately, parallel):** **M3** Activities (build `#38` activity-type model
    first — nearly everything downstream needs it) ∥ **M5** Todos (no dependency on M3/M4, only
    needs the already-shipped Apiaries) ∥ **M7** Admin App (a separate web app, zero dependency
    on M3–M6) ∥ **M8**'s groundwork — the AI provider research spike and EPIC-14's GDPR framework
    have no code prerequisites and have their own lead time, worth starting early.
  - **Phase 2 (once M3's `#38`/`#39` land):** **M4** Journeys (`#46`, the journey picker, needs
    the Activities model) and **M6** Export (needs Activities' `#38` and Journeys' `#45`).
  - **Phase 3 (once M5 lands):** **M9** Settings & Notifications (`#82` needs the Todos due-date
    field).
  - **Phase 4 (once M3+M4+M5 are far enough along):** **M8**'s core query/write features (need
    Activities' `#38`, Todos' `#50`/`#51`, and Journeys' `#46`/`#48` for full context-scope
    coverage).
  - **Phase 5 (native rollout, deliberately last per D-10):** **M10** Android, then **M11** iOS &
    on-device AI — no code dependency on M3–M9, but D-10's own rationale ("native only when a
    feature needs it") argues against front-loading this.
  - **Phase 6 (explicitly deferred to the very end, D-25):** **M12** Import (Apiaries).
  - This phasing is exactly what an `ecc:orch-*` agent run at the milestone level should follow;
    each milestone's GitHub description carries a short phase tag for the same reason.

## D-15 — Apiary distance: straight-line (haversine), offline

- **Decision:** the two-apiary distance feature (FR-AP-5) computes **straight-line (haversine)
  distance**, works **fully offline**, and is shown in **km**. The two apiaries are chosen by a
  **tap-to-select** interaction on the map (tap two pins), per the Melargil prototype's "medir
  distância" flow.
- **Deferred:** **driving distance** (needs an online routing service) is not built in v1 — kept
  as an optional future enhancement, revisit only if field feedback asks for it. Distance _from
  the user's current location_ is already covered separately by proximity ordering (FR-AP-2) and
  is not part of this feature.
- **Supersedes:** Q-DIST. Touches FR-AP-5, #37.

## D-16 — Map: `flutter_map` markers + user location + measure overlay; tile provider deferred

- **Decision:** the apiary map view (FR-AP-3) renders **pin markers per apiary** (showing hive
  count), a distinct **user-location marker**, and the tap-to-measure overlay (D-15), built on
  `flutter_map` + MapLibre/OSM tiles (already the stack per `tech-stack.md`). This resolves the
  map _interaction/UX_ shape.
- **Still open (narrowed Q-MAP):** the **tile provider and offline-tile caching strategy** —
  which has real licensing/cost implications for production traffic — is **not** decided here and
  does **not** block M2: FR-AP-3's acceptance criteria only require the map to render online,
  without error, for a reasonable marker count. M2 ships with the public OSM/MapLibre demo tile
  endpoint (dev/low-traffic use, proper attribution), and offline-tile caching + a paid/self-hosted
  tile provider decision is deferred to a follow-up (tracked as the narrowed Q-MAP below).
- **Refinement (2026-07-13 user decision, #257):** the map's **default layer is satellite**
  imagery (Esri World Imagery, no API key required), not the OSM streets layer — field users
  recognize terrain/tree cover more readily than street outlines. A gloves-friendly in-map toggle
  switches satellite ⇄ streets, the choice persists for the session (survives list⇄map view
  switches, not an app restart), and both layers now carry a visible attribution overlay for
  their active source (Esri's "Powered by Esri" + credits, or OSM's "© OpenStreetMap
  contributors" — previously missing for OSM too). This only changes which _online_ tile source
  is shown by default and how it's toggled/attributed; it does not pick a production tile
  provider or resolve offline-tile caching — both remain open per the narrowed Q-MAP below.
- **Supersedes (partially):** Q-MAP — the marker/location/measure UX is resolved; the tile
  provider/offline-tiles question is kept open (narrowed) in `open-questions.md`. Touches FR-AP-3,
  FR-OF-1, #34, #257.

## D-17 — Apiary search: client-side, apiaries-only, by name/location

- **Decision:** search (FR-AP-6) is scoped to **apiaries only** in v1, runs **client-side** over
  the locally-synced apiary set (so it works fully offline per FR-OF-1), and matches on **name**
  and **location** (the apiary's stored location label/address text, not free-text notes), per the
  Melargil prototype's apiary-list search.
- **Realized (#252/#254):** the "location label/address text" this decision anticipated is the
  apiary's new optional free-text `place_label` column (#252, e.g. "Montargil") — search now
  matches name OR `place_label`, case- and diacritic-insensitive (PT "São" ≈ "sao"). Not a
  revision of this decision, just its originally-intended scope materializing once the field
  existed to search against (client/lib/features/apiaries/apiaries_repository.dart's
  `filterApiariesByQuery` previously noted this gap explicitly).
- **Deferred:** extending search to activities/journeys/todos is out of scope for FR-AP-6 — it is
  a separate, future cross-entity search requirement (not yet specified) to consider if/when those
  domains land.
- **Supersedes:** Q-SEARCH. Touches FR-AP-6, #36, #252, #254.

## D-18 — Accessibility baseline: WCAG 2.2 AA, 44x44 tap targets

- **Decision:** the app's documented accessibility standard is **WCAG 2.2 AA** (FR-AX-1). Beyond
  WCAG 2.2's own 24x24 CSS px target-size minimum (SC 2.5.8), field-first primary/secondary
  actions (FR-UX-1) use a **44x44 minimum tap target**, with the single primary action per screen
  (save/sign-in/submit) at **56px tall**, gloves-friendly per the Melargil prototype's 52-60px
  control sizing (`docs/design/prototype.md`). Both numbers are enforced by an automated test
  sweep, not just convention — see `client/test/a11y_field_ux_test.dart` and
  `client/test/core/widgets/field_action_button_test.dart` (built on the shared
  `expectMinTapTarget` helper in `client/test/support/a11y_matchers.dart`), which generalize
  `apiaries_list_screen_test.dart`'s original toggle-segment test that predates this decision.
- **Reusable checklist:** `docs/design/accessibility-field-ux-checklist.md` is the one checklist
  other epics' feature stories use to verify a11y/field-first UX consistently (FR-AX-1 AC,
  FR-UX-1 AC) — tap-target size, focus order/visible focus indicator, semantics labels, contrast,
  gloves-friendly spacing, and the manual screen-reader/keyboard/gloved-use pass procedure.
- **Reusable components:** shared tap-target-sized building blocks live in `client/lib/core/widgets/`
  (`PrimaryActionButton`/`SecondaryActionButton`) rather than each screen hand-rolling button
  sizing — see that directory's doc comments.
- **Supersedes:** Q-AX. Touches FR-AX-1, FR-UX-1, NFR-TST-1, #79, #80.

## D-19 — PT/EU beekeeping & honey-traceability obligations scoped; HIPAA dropped

- **Decision:** **HIPAA does not apply** — it is US human-healthcare law with no
  extraterritorial reach here, and separately, bee/apiary health records are not GDPR Art. 9
  "special category" data (Art. 9 health data is limited to natural persons). Remove HIPAA
  from NFR-CMP-1. **GDPR applies** (already affirmed) with ordinary (non-special-category)
  handling for treatment/health-of-bees records.

  To be explicit: GDPR fully applies to the app's personal data — user profiles,
  organization/membership data (sole traders are natural persons), free-text notes,
  apiary coordinates linkable to an individual, and audit logs. The only things decided
  here are that bee-health records are not special-category data and that HIPAA is
  irrelevant. Export and erasure must cover all five personal-data surfaces (see
  "What IS personal data in BeekeepingIT" in the research note's Finding A).

  The concrete **Portuguese/EU beekeeping and honey-traceability obligations** are enumerated
  in [`docs/research/regulatory-pt-eu-beekeeping.md`](../docs/research/regulatory-pt-eu-beekeeping.md)
  (#91). None block current M0-M2 scope; the following are accepted as **future-relevant data
  points**, to be triaged into concrete FR/NFR changes when the owning feature epic
  (apiaries/activities/import-export) is planned:

  - Beekeeper/apiary DGAV registration number (optional field).
  - Annual stock-declaration record (Sept 1-30 window + 20%/20-colony interim trigger),
    distinct from the live hive count (FR-AP-7/D-2).
  - Optional structured disease/condition field on Treatment activities (FR-AC-1), informed
    by DGAV's mandatory-notification disease list (DDO).
  - A retention-policy note reconciling GDPR erasure (FR-HIS-1) with the ~5-year veterinary
    treatment record-keeping expectation (Reg (EU) 2019/6).
  - Optional lot/batch identifier on Honey harvest activities (FR-AC-1), for future
    traceability/export features (Reg (EC) 178/2002 Art. 18, Reg (EU) 931/2011, Dir
    2011/91/EU, Dir 2001/110/EC as amended by Dir (EU) 2024/1438).

- **Supersedes:** Q-CMP, Q-REG. Touches NFR-CMP-1, Context C-2, #91.
- **Not decided here (deferred to feature epics):** whether/when to actually implement any of
  the five future-relevant data points above. This decision **scopes the obligations**, it
  does not commit to schema changes.

## D-20 — Apiary counters: typed 1-N child table, decoupled from the apiaries row

- **Decision (user, 2026-07-13):** an apiary's countable current-state quantities live in a
  **1-N child table `apiary_counters`** (`apiary → counters`), **not** as columns on the
  `apiaries` table. Each row is one **typed counter** — `(id, organization_id, apiary_id →
apiaries ON DELETE CASCADE, counter_type text, value int CHECK ≥ 0)` — with **`UNIQUE
(apiary_id, counter_type)`**, so an apiary can never hold two counters of the same type (apiary
  X can never have two "hive" counts). The **known set of counter types** is **validated in the
  owning service** (initially `['hive']`), **not** a DB enum/CHECK on the type — mirroring the
  `data-model.md` §2 "extensible enums" convention (activity `type`, membership `role`) — so
  adding a future countable (nucs, supers, queens, …) is a **code-only append** (server + client
  constants), with **no `apiaries`-table migration**.
- **Hive count is now a counter row.** This **revises D-2's shape** (which kept hive count as a
  plain `apiaries.hive_count` column): the column is **retired**, existing values migrated into
  `hive` counter rows, and the sync-rules bucket, the REST/sync wire shape, and the client schema
  were coordinated in the **same change** (walking-skeleton phase, no legacy clients). **D-2's
  substance stands:** there are still **no hive entities**, and the current-state-vs-event split
  is unchanged — a counter is the apiary's **current state** ("how many hives are here now"),
  while an activity's `hives_involved` attribute is an **event record** ("how many hives this
  harvest touched"). The two are complementary, not redundant.
- **Behavior:** on the detail screen the **hives counter always displays (0 when no row exists)**;
  every other known type renders **only when a row exists**, built generically over the known set
  so a future type appears by adding a constant. Counter writes flow through the offline-sync path
  as their own `apiary_counter` op — record-level LWW keyed by `(apiary_id, counter_type)` with
  upsert semantics (the client-generated row id is not the server's identity) — and are audited in
  `apiaries.audit_log` under `entity_type = 'apiary_counter'` like any change (FR-HIS). API/sync
  reads still expose a top-level `hive_count` field (resolved from the counter, 0 when absent), so
  the decoupling is invisible to consumers.
- **Supersedes/refines:** the `hive_count`-column part of **D-2** (kept as a counter, not an
  entity). Touches **FR-AP-7**, FR-HIS-1, D-6 (sync), #256. Design in
  [`docs/architecture/data-model.md`](../docs/architecture/data-model.md) §7.

## D-21 — Journey attribution: smart auto-select with manual override

- **Decision:** an activity carries a **stored, nullable `journey_id`** link — not a purely
  derived value. When logging an activity, the app looks for an **open** journey whose apiary
  and activity type match the activity being logged, and **pre-fills** that journey as the
  activity's `journey_id` (a default, not a hard rule). From the activity form the user can:
  **deselect** the pre-filled journey (leaves `journey_id` null); **switch** to a different
  matching open journey; **create a journey on the spot** (a shortcut starts a new journey —
  name + apiaries + main activity — without leaving the activity form, then attaches the
  activity to it); or **attach to a closed journey** (closed journeys are selectable but
  hidden by default behind a "show hidden journeys" toggle, and saving against one requires an
  explicit confirm-to-proceed warning).
- **Progress and statistics** ("feitos/planeados"; apiaries visited, hives harvested — Σ
  hive-count attribute, D-2 — honey kg, média alças/colmeia) are computed from the **stored**
  `journey_id` links, not a live re-match — editing/deleting an activity, or re-scoping a
  journey's plan, does not retroactively change other activities' links.
- **Narrows FR-JO-4** to one main activity per journey for M4; a manual per-apiary
  activity-list plan is a deferred future extension.
- **Supersedes:** Q-JOUR. **Touches:** FR-JO-1, FR-JO-4, #38, #39, #46.

## D-22 — Cloud AI provider & GDPR posture

- **Decision:** the cloud AI provider is **not yet chosen** — Google, AWS, Anthropic, and
  other candidates are all live options, resolved via a dedicated research spike (EPIC-08)
  rather than assumed to be any one vendor. Hard requirements for the chosen provider: a
  signed **Data Processing Agreement**, and **EU-region processing** available (or an
  explicit, user-consented exception if unavailable). **Not** a hard requirement: a
  no-training/no-retention-for-training guarantee — the research spike records whether each
  candidate offers one and prefers a provider that does when terms are otherwise comparable,
  but a provider that may train on submitted data is acceptable **provided the consent screen
  discloses this plainly** (an explicit "may be used to improve provider models" line, not
  just "sent to a processor").
- **PII minimization rule:** prompts sent to the provider carry only the data needed to
  answer the scoped question; personal identifiers (names, emails, etc.) are minimized or
  omitted where not required to answer it.
- **Consent UX:** drafted against GDPR requirements and general good practice at spec/design
  time (not specified further here).
- **Supersedes:** Q-AICLOUD. **Touches:** FR-AI-1, NFR-AI-1, NFR-CMP, #63, #66,
  EPIC-08's provider-research story.

## D-23 — Todo assignment: optional assignee, not an access boundary

- **Decision:** todos gain an optional `assignee` field, referencing an org member. Default
  is unassigned. Both assigned and unassigned todos remain **visible and actionable to every
  member of the organization** (FR-TEN-2) — assignment is a "who's taking this" hint, not an
  access-control boundary.
- **Supersedes:** Q-TODO. **Touches:** FR-TD-1.

## D-24 — Notifications: in-app only for v1, checked on app-open

- **Decision:** the v1 notification system covers two event families: **todo due-date
  reminders** (FR-TD-1) and **sync results** — a push failure that needs the user to fix
  rejected queued changes (FR-OF-2's notify-and-fix rule) and sync completion. Delivery is
  **in-app only** (toast/banner via the existing app-shell chrome — offline banner, sync
  pill, save/sync toasts); there is no backend push service or device-token registration in
  the PWA phase, so **push notifications are deferred to the native phase** (M10/M11, EPIC-15).
  Because there's no background service in the PWA phase, the notification check runs **when
  the app is opened or brought to the foreground**, not on a timer or poll.
- **Supersedes:** Q-NOTIF. **Touches:** FR-ST-1, FR-TD-1, FR-OF-2, #82.

## D-25 — Import semantics: apiaries-only, merged with assisted matching, deferred to M12

- **Decision:** v1 import is scoped to **apiaries only** (not activities or journeys), and is
  delivered in its own milestone (**M12**), scheduled after all other feature milestones —
  reflecting that it is a lower-priority, more migration/admin-flavored capability than the
  rest of the field app (D-14 revised accordingly). Import **merges** with the existing
  apiary set: when an imported apiary's name matches an existing one, the app **suggests the
  match** to the user ("is this the same apiary?") rather than silently merging or silently
  creating a duplicate — the user decides per suggested match whether to merge into the
  existing record or create a new one. Imported apiaries **always receive newly-generated
  IDs**; file-supplied IDs are never trusted as identity. A **dry-run preview** (what will be
  created / updated / left as a suggested-match decision) is mandatory before the import
  commits. Import writes flow through the normal apiaries-service write path — record-level
  LWW (D-6), atomic write-back + validation parity (D-12), history capture (FR-HIS-1) — no
  privileged import bypass.
- **Supersedes:** Q-IMP. **Refines:** D-14 (milestone list, adds M12). **Touches:** FR-IE-2,
  #70.

## D-26 — Cloud hosting: Scaleway Kapsule (managed Kubernetes)

- **Decision (user, 2026-07-18):** production/staging deployment targets **Scaleway Kapsule** — a
  **managed Kubernetes control plane** (free, HA, EU-region) with pay-as-you-go worker nodes.
  Kept **vanilla/portable per NFR-ARC-2**: no Scaleway-specific managed services (managed
  database, managed IAM, etc.) are adopted — the existing self-hosted stack (CloudNativePG
  Postgres, Authentik, PowerSync, MinIO) deploys **unchanged** onto Kapsule via the existing Helm
  umbrella chart + Flux GitOps (D-13), the same way it deploys onto the local k3d dev cluster
  today.
- **Alternatives considered:** **Hetzner Cloud** (cheapest, but self-managed k3s — extra ongoing
  control-plane ops burden the project doesn't need yet); **OVHcloud MKS** (also a free EU managed
  control plane, but pricier entry, ~€18/mo vs. Scaleway's ~€6.34/mo); **DigitalOcean, IBM Cloud,
  AWS, GCP, Azure** (all can satisfy the compliance bar below with an EU region + signed DPA, but
  cost more and/or fit less naturally for a small, cost-conscious single-org v1, per C-1/D-4).
- **Compliance bar (not a data-sovereignty requirement):** the deciding compliance constraint is
  the same one **D-22** already established for the AI provider — an **EU-region + signed DPA**,
  not a requirement that the vendor itself be EU-incorporated. Scaleway (French, EU-native) clears
  this easily; it was chosen on **cost + low ops burden**, not because non-EU vendors would have
  failed `NFR-CMP-1`.
- **Why Scaleway specifically:** its managed control plane is **free permanently** (not a trial),
  the cheapest of the managed options evaluated, and its **S3-compatible Object Storage** is a
  drop-in swap for MinIO later — exactly what `NFR-ARC-2`'s "object storage now, swap to cloud
  later" already anticipated.
- **Scope — this decision is the hosting provider only.** It does **not** resolve **Q-DR**
  (backup/DR targets — still open) or **#90** (GDPR data export/erasure UI), both scheduled at
  **M6 · Export** in the D-14 phase plan. Standing up a Scaleway cluster **ahead of that work**
  means the first real deployment should be **staging-grade** (the already-scaffolded, currently
  unused `environments/staging.yaml`) — not a `prod` environment holding real user data — until
  DR and GDPR export/erasure land. Also not yet covered: production-grade TLS (currently
  self-signed, dev/CI-grade — see `docs/architecture/platform.md`'s "Not yet covered here") and
  Authentik/RBAC hardening, both still open under EPIC-14 (#15).
- **Supersedes:** none — no `Q-*` previously tracked cloud-hosting choice; this is a new decision.
- **Touches:** `NFR-ARC-2`, `NFR-ARC-3`, `NFR-CMP-1`, D-13 (GitOps extends to a new
  `clusters/`/`apps/` env), D-22 (analogous DPA/EU-region bar), `infra/`,
  [`docs/architecture/platform.md`](../docs/architecture/platform.md), EPIC-14 (#15, #90, #92).

## D-27 — Deploy pipeline: release-triggered, PR-based promotion (replaces GitOps image-automation)

- **Decision (user, 2026-07-19):** deployments are driven by **published GitHub Releases**, not by
  Flux image-automation watching the registry. A release tag suffixed `-rc` (e.g. `v1.2.3-rc1`)
  targets **staging**; an un-suffixed tag (`v1.2.3`) targets **prod**, gated behind the `production`
  GitHub Environment's required-reviewer approval. CI builds and tags the image set for that exact
  release version and opens a small tag-bump **pull request** against the GitOps state; a human
  merges it and Flux (unchanged, still read-only) reconciles. No component ever holds a standing
  git-write credential, and the flow works within `main`'s existing PR-only branch protection.
- **Why image-automation was dropped:** Flux's `image-automation-controller` requires a **standing
  git-write credential** (a deploy key) to auto-commit tag bumps to `main` — rejected by the user. A
  direct-push-after-approval variant is also **impossible on this repo**: `main` requires PRs, and
  GitHub's "allow specified actors to bypass required PRs" is **organization-repo-only** — this is a
  personal (`owner_type: User`) repo, so nothing short of a repo-admin credential could push, which
  is the same standing secret merely relocated. The release → PR → merge pattern needs no standing
  credential at all.
- **GitOps repo split:** `infra/gitops/` moves to its own **`beekeepingit-gitops`** repo; the Helm
  chart (`infra/helm/beekeepingit/`) stays in this repo. Now that the mechanism is PR-based (not
  direct-push) this is pure structural hygiene, not a security trade-off — Flux sources the chart
  from this repo and the release-manifests from the new one (a supported split). `release-deploy.yml`
  opens its tag-bump PR against the new repo, which needs a scoped token or a small GitHub App
  (tracked in `FOLLOWUPS.md`).
- **Supersedes:** [ADR-0014](../docs/adr/0014-cicd-pipeline.md)'s decision #4 (deploy via Flux
  image-automation). The image-reflector/image-automation controllers, the `ImageRepository`/
  `ImagePolicy`/`ImageUpdateAutomation` objects, and every `$imagepolicy` setter marker are removed;
  `build-publish.yml` stays as pure per-PR CI (lint/test/build/scan), no longer a deploy trigger.
- **Recorded in:** [ADR-0018](../docs/adr/0018-release-triggered-deploy-pipeline.md).
- **Touches:** `NFR-ARC-3`, `NFR-MNT-1`, D-13 (Flux GitOps unchanged, still read-only), D-26 /
  [ADR-0017](../docs/adr/0017-scaleway-cloud-hosting.md), EPIC-13 (#88), EPIC-14 (#89 — the git-write
  credential this removes the need for).

---

## Open Spikes

- **SP-1** — ✅ **RESOLVED (2026-07-01) → PowerSync** (self-hosted Open Edition). Head-to-head +
  a working k8s prototype (create → offline edit → sync + server-authoritative LWW/conflict-log).
  Recorded in [ADR-0005](../docs/adr/0005-sync-engine-choice.md) /
  [SP-1 report](../docs/spikes/sp-1-powersync-vs-electricsql.md); resolves the D-6 sync engine.
- **SP-2** — On-device LLM feasibility: model + runtime + NL→query accuracy on a
  mid-range phone. **Re-scoped to the native phase** (D-8/D-10) — not PWA-blocking.
