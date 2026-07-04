# Decisions Log

Resolved decisions that supersede the corresponding open questions. Newest context
wins over earlier requirement wording.

> Decisions are the working **default, not immutable**. If contradicting one makes sense,
> propose it to the user; on confirmation, update it here (and the affected requirements).

_Last updated: 2026-06-27._

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
    enforcement *mechanism* (FR-AU-2, NFR-RL-1) but **no billing UI or quota
    enforcement** in v1; everything free.
  - **On-device/local AI** — deferred to the **native phase** (can't run in a PWA).
    The PWA phase ships **cloud AI** instead (see D-8 — this reverses the earlier
    local-only-first stance).
- **Kept in v1** (explicitly *not* deferred):
  - **Web Admin App** (NFR-ROL-2) — in scope for v1 (role/org management).
  - **CSV/JSON import & export** (FR-IE-1/2) — in scope for v1.
- **Supersedes:** Q-SUB, Q-RL (deferred); partially Q-LLM (cloud path deferred —
  on-device model feasibility still needs a spike).

---

# Technology Stack

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

## D-7 — Identity & auth: Keycloak (self-hosted)
- **Keycloak** (OIDC/OAuth2) on the k8s cluster; **realms + roles** for RBAC
  (NFR-ROL); **offline token caching** for field login; **app-level org-scoped
  authorization** layered on top (FR-TEN).
- **Supersedes:** Q-AUTH — mechanism **and** offline-login now designed in
  [`docs/architecture/auth.md`](../docs/architecture/auth.md) / [ADR-0004](../docs/adr/0004-authn-authz.md).

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
  and owner-mediated"** (the *AI write-safety guarantee*, NFR-AI-4).
- **Why:** preserves bounded-context ownership (no service writes another's schema), keeps the
  untrusted NL/LLM **blast radius contained** (LLM output is a *proposal*, never a direct DB
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
  enforces**, as closely as feasible, *before* pushing, to catch failures locally rather than
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
  (`CONTRIBUTING.md`). After the one-time apply, `infra/gitops/` is self-managed by Flux.
- **Reconciliation is polling-only** (`GitRepository` interval, no GitHub webhook receiver) — the
  local cluster has no public endpoint for GitHub to call.
- See [`infra/gitops/README.md`](../infra/gitops/README.md) and
  [ADR-0008](../docs/adr/0008-gitops-flux.md). Touches `NFR-ARC-3`, `NFR-MNT-1`, `#86`.

---

# Open Spikes

- **SP-1** — ✅ **RESOLVED (2026-07-01) → PowerSync** (self-hosted Open Edition). Head-to-head +
  a working k8s prototype (create → offline edit → sync + server-authoritative LWW/conflict-log).
  Recorded in [ADR-0005](../docs/adr/0005-sync-engine-choice.md) /
  [SP-1 report](../docs/spikes/sp-1-powersync-vs-electricsql.md); resolves the D-6 sync engine.
- **SP-2** — On-device LLM feasibility: model + runtime + NL→query accuracy on a
  mid-range phone. **Re-scoped to the native phase** (D-8/D-10) — not PWA-blocking.

