# Functional Requirements

Each requirement has a **stable ID** (e.g., `FR-AP-1`) for traceability into
planning, design, and test artifacts. IDs are grouped by domain. The wording is
refined from the original `frs.txt` but preserves the original intent; typos and
ambiguities flagged inline link to `open-questions.md`.

| Prefix | Domain                              |
| ------ | ----------------------------------- |
| FR-AP  | Apiaries                            |
| FR-AC  | Activities                          |
| FR-JO  | Journeys                            |
| FR-TD  | Todos                               |
| FR-AI  | AI / Chatbot                        |
| FR-OF  | Offline & Sync                      |
| FR-IE  | Import / Export                     |
| FR-ONB | Onboarding (Profile & Organization) |
| FR-AU  | Accounts & Subscription             |
| FR-TEN | Tenancy & Data Ownership            |
| FR-HIS | History / Audit                     |
| FR-ST  | Settings                            |
| FR-PL  | Platforms & Devices                 |
| FR-UX  | Usability (field-first)             |
| FR-AX  | Accessibility                       |

---

## Apiaries (FR-AP)

- **FR-AP-1** — Full **CRUD** for apiaries (create, read, update, delete).
- **FR-AP-2** — **List** of apiaries ordered by **proximity** to the user's
  current location (closest first).
- **FR-AP-3** — **Map view** showing a marker for each apiary's location and a
  marker for the user's current location.
  - _Resolved (D-16):_ `flutter_map` markers + user location + measure overlay;
    tile provider/offline-tile caching stays open (narrowed Q-MAP), doesn't block v1.
  - _Refined (D-16, #257):_ satellite (Esri World Imagery) is the default layer, with a
    gloves-friendly in-map toggle down to streets (OSM) — both attributed, choice persists
    per session. Production-traffic tile provider + offline-tile caching remain open (Q-MAP).
- **FR-AP-4** — Users can **switch** between map view and list view; both must be
  available.
- **FR-AP-5** — Feature to **measure the distance between two apiaries**.
  - _Resolved (D-15):_ straight-line (haversine), offline, tap-two-pins selection;
    driving distance deferred.
- **FR-AP-6** — **Search** apiaries by **name, location, or other attributes**.
  - _Resolved (D-17):_ client-side, apiaries-only, name + location; extending to
    other entities deferred.
- **FR-AP-7** — **Apiary detail page** showing name, location, number of hives,
  and other relevant details.
  - _Resolved (D-2):_ "number of hives" is a **count** on the apiary; hives are
    **not** a separate entity.
  - _Refined (#341, product-owner-directed, 2026-07-21):_ an apiary's **location
    is mandatory** — it can never be created or saved without coordinates.
    Enforced at every layer: the create/edit form validation, the OpenAPI
    `ApiaryCreate.required` + REST service validation, the offline sync-apply
    validation (a location-less `put` is rejected), and a DB `NOT NULL`
    constraint (`00008_apiary_location_not_null.sql`). This supersedes the
    walking-skeleton-era "location optional" behavior the earlier
    `00003_add_apiary_location.sql` migration and the original `ApiaryCreate`
    schema assumed.
- **FR-AP-8** — An apiary may carry optional **free-text notes**, editable
  from the apiary form and shown on the detail page. Notes sync offline and
  are **history-tracked** (FR-HIS) like other apiary edits.
  - _Prototype:_ Melargil apiary detail (see
    [`docs/design/prototype.md`](../docs/design/prototype.md)).

## Activities (FR-AC)

- **FR-AC-1** — Activities have a **type**, and each type defines its **own set of
  attributes**. Types are well-defined and **extensible** in the future. Initial
  types:
  - **Honey harvest** — date, amount of honey harvested, number of hives harvested,
    **number of honey supers (alças) harvested**, notes. The supers count is the
    **primary yield metric** (more reliably measured in the field than the kg
    amount).
  - **Feeding** — date, type of feed, amount of feed, notes.
  - **Treatment** — date, **treatment context**, type of treatment, notes. Treatment
    context distinguishes: a general/preventive treatment (no disease tied to it);
    a specific treatment tied to a named disease/condition (from a DGAV-DDO-informed
    list); or a detection-only report (a disease observed, no treatment applied yet).
  - **Generic** — date, notes.
  - _Per D-2:_ relevant types (harvest, and optionally treatment/feeding) capture a
    **number-of-hives-involved** attribute; activities stay at the apiary level.
  - _Confirmed 2026-07-16 (user):_ the honey-supers attribute and the treatment
    context distinction (D-19 future-relevant data points) are now committed v1
    scope, not deferred.
- **FR-AC-2** — **Add** an activity to an apiary: select the activity type and
  fill in the relevant attributes.
- **FR-AC-3** — **Edit** an existing activity, updating the relevant attributes.
- **FR-AC-4** — **Delete** an existing activity.
- **FR-AC-5** — On the **apiary detail page**, view a list of all activities for
  that apiary, **filterable by activity type and date range**.
- **FR-AC-6** — On the **main activities page**, view a list of all activities
  across **all apiaries**, **filterable by activity type and date range**.
  - _Resolved (D-2):_ activities are recorded per **apiary**; hive counts are
    activity attributes, not separate hive records.

## Journeys (FR-JO)

A **journey** aggregates seasonal work across apiaries (e.g., the spring honey
harvest, which requires visiting all apiaries).

- **FR-JO-1** — **Journey statistics page**: select a journey and view aggregated
  metrics — apiaries visited, hives harvested, honey collected, how much is still
  **missing** (planned vs. done), etc.
  - _Per D-2:_ "hives harvested" = **sum of the number-of-hives-harvested
    attribute** across harvest activities in the journey.
- **FR-JO-2** — **Main journeys page**: list all journeys, **filterable by date
  range and activity type**.
- **FR-JO-3** — **Journey detail page**: apiaries visited, activities performed at
  each apiary, and the aggregated statistics for that journey.
- **FR-JO-4** — **Add a journey**: select the apiaries to be visited and **one main
  activity type** to be performed (per-apiary activity lists are a deferred future
  extension — see D-21).
  - _Resolved (D-21):_ executed activities are attributed by **smart auto-select
    with manual override** — the app pre-fills a matching open journey by default;
    the user can deselect, switch, create a journey on the spot, or (with a
    warning) attach to a closed journey. "How much is missing" derives from these
    stored attributions.

## Todos (FR-TD)

- **FR-TD-1** — Create **todos** with **title, description, due date, priority
  level, and an optional assignee**. Todos support a full lifecycle — create, edit,
  **complete/reopen**, delete — and may be associated with a specific **apiary**,
  or left as a general, org-level todo (no separate "area" entity; the AI example
  "todos pending for the area of apiary X" is served by the apiary association).
  Todos are easily accessible from the **main screen**, the **apiaries list**, and
  the **apiary detail page**. Provide a list of all todos, **filterable and
  sortable by due date and priority level**.
  - _Resolved (D-23):_ optional assignee (an org member), default unassigned;
    assignment does not restrict visibility (FR-TEN-2 — every org member still
    sees every todo).

## AI / Chatbot (FR-AI)

- **FR-AI-1** — A **chatbot** that answers natural-language questions about
  beekeeping, apiaries, activities, journeys, todos, and related topics, using the
  **app's own data**. The user can select the **context scope**: a specific
  organization (default), a specific apiary, or a specific journey. Example
  questions it must handle:
  - "What are the activities performed at apiary X in the last month?"
  - "What is the total amount of honey harvested in the last year?"
  - "What are the todos due in the next week?"
  - "What are the todos that are overdue?"
  - "What are the todos that are pending for the area of apiary X?"
  - _Constraints (D-8):_ scoped to the selected context; **cloud AI now**
    (online-only), **on-device later** — see `non-functional-requirements.md`
    (NFR-AI group) and `decisions.md` (D-8).
  - _Resolved (D-22):_ provider selection (via a research spike), DPA requirement,
    EU-residency requirement, no-training posture, and PII-minimization rule are
    governed by D-22 (Q-AICLOUD resolved).
- **FR-AI-2** — Beyond answering, the assistant can **propose actions** on the app's
  data from a natural-language (or **voice**) request — e.g. _"set apiary X to 12
  hives"_, _"mark the todo for apiary Y as done"_, _"log a 10 kg honey harvest at
  apiary Z"_. Every AI-proposed **create/update/delete requires explicit user
  confirmation** before it runs, and executes through the **normal domain write path**
  (same validation, authorization, tenancy, and history as a manual edit). The `ai`
  service itself **never writes** — it only proposes.
  - _Constraints (D-11):_ propose → confirm → owner-executes; **cloud + online-only** in
    the PWA phase; see NFR-AI-4 and `decisions.md` (D-11). Voice input is an EPIC-08 spike.

## Offline & Sync (FR-OF)

- **FR-OF-1** — The app is used **mainly in the field**, so it must **work offline**
  and **sync data when an internet connection is available**.
  - _Resolved (was Q-SYNC):_ conflict resolution when multiple org users edit the same data
    offline is **server-authoritative record-level last-write-wins + a conflict log** — designed
    in [`docs/architecture/sync.md`](../docs/architecture/sync.md) / ADR-0006 (#106).
- **FR-OF-2** — **Sync failure handling.** A client→server sync **push is atomic**: if any
  queued change is rejected, the **entire push is rolled back** (no partial apply). Before
  pushing, the client **revalidates** queued edits against the **same rules the server will
  apply** (as closely as feasible) to catch problems offline. On rejection, the **user who
  pushed is notified**, shown the offending change(s), and **resolves them on the client**
  before re-pushing. The server remains authoritative.
  - _Decision (D-12):_ atomic write-back + client validation parity + notify-and-fix. Mechanism
    designed in [`docs/architecture/sync.md`](../docs/architecture/sync.md) §6/§8/§9 (#106); the
    **failure-handling screens** are built in EPIC-06.
- **FR-OF-3** — **Connection-quality-gated sync.** Having connectivity is **not sufficient** to
  attempt a sync: the client **measures connection quality** and only starts a push (or stream
  reconnect) when quality clears a **configurable threshold** (roughly "usable 3G or better").
  Field sites often have short windows of **very weak** signal where an attempted sync stalls or
  fails mid-operation; gating on measured quality keeps the FR-OF-2 failure/retry path **rare**
  instead of routine. A **manual "sync now"** action always attempts once, regardless of the
  gate. The gate is a client-side **optimization only** — sync correctness (atomic push,
  idempotent retry, D-12) never depends on it.
  - _Mechanism:_ designed in [`docs/architecture/sync.md`](../docs/architecture/sync.md) §7.1;
    built in EPIC-06.

## Import / Export (FR-IE)

- **FR-IE-1** — **Export** apiaries, activities, and journeys in a common format
  (e.g., CSV or JSON) for backup or analysis.
- **FR-IE-2** — **Import apiaries** from a common format (e.g., CSV or JSON) for
  backup or analysis. v1 scope is apiaries only (activities/journeys import is
  deferred); delivered in its own milestone, M12, scheduled last in the rollout.
  - _Resolved (D-25):_ merge with assisted name-matching (the app suggests a match,
    the user decides merge-vs-create), imports always receive new IDs, and a
    dry-run preview is mandatory before commit.

## Onboarding — Profile & Organization (FR-ONB)

- **FR-ONB-1** — On first login, users must **create their profile** (name, email,
  and other relevant info). Profile completion is **enforced** before accessing
  main features.
- **FR-ONB-2** — Before viewing apiaries, users must **create their organization**
  (name, address, and other relevant info; some fields may be optional).
  Organization completion is **enforced** before accessing main features.
  - _Resolved (D-3):_ the user who **creates** an organization becomes its
    **admin**; other users **join an existing org via email invitation**.
- **FR-ONB-3** — **Organization membership & invitations**: the org admin can
  **invite members by email**; invited users join the existing organization. The
  org creator is the first admin (see NFR-ROL-1). _(Detail still open: invite
  expiry/re-invite, removing members, transferring admin.)_

## Accounts & Subscription (FR-AU)

- **FR-AU-1** — Manage **account settings**: change password, update profile
  information, and manage subscription (if applicable).
- **FR-AU-2** — **Subscription-based feature toggles**: some features may be
  premium-only, others available to all; the app enforces access by subscription
  level. **For now, all features are available to all users**, but the mechanism
  must exist for future restriction.
  - _Resolved (D-4):_ **v1 ships the toggle/enforcement mechanism only** — **no
    billing or subscription UI**, everything free. Real billing is deferred.

## Tenancy & Data Ownership (FR-TEN)

- **FR-TEN-1** — The app supports **multiple users**, each with their **own
  account and login credentials**, and **enforces access control** so users only
  access data they are entitled to.
- **FR-TEN-2** — The **Organization is the unit of ownership**. Apiaries,
  activities, and journeys **belong to the organization**, and **all users within
  an organization share the same data** — except that **each activity is recorded
  against the user who performed it**. Access control ensures users only access
  data belonging to **their own organization**.
  - _Interpretation:_ the original text's "users have their own data, cannot see
    each other's data" (frs line 28) is reconciled here as **organization-level**
    isolation, not per-user isolation. See `open-questions.md` (Q-TEN).

## History / Audit (FR-HIS)

- **FR-HIS-1** — Maintain a **change history** for all entities. Every create,
  update, or delete (apiary, activity, journey, or any other entity) records the
  **user who made the change** and the **timestamp**. Provide a feature to **view
  the history** of changes for each apiary, activity, and journey.
  - _Resolved (Q-HIS):_ the history architecture — append-only per-entity model,
    per-service in-transaction capture, immutability, retention, GDPR-erasure
    handling, visibility, and offline/sync behaviour — is decided in
    `docs/architecture/history.md` + `docs/adr/0007-history-audit.md` (#107).

## Settings (FR-ST)

- **FR-ST-1** — Allow users to **customize app settings**, including notification
  preferences, data sync settings, and other relevant options.
  - _Resolved (D-24):_ v1 notification events are todo due-date reminders and sync
    results (failure-needs-fixing + completion); delivered **in-app only**, checked
    when the app is opened; push is deferred to the native phase (M10/M11).

## Platforms & Devices (FR-PL)

- **FR-PL-1** — Support **Android and iOS**, on both **phones and tablets**, and
  on **larger devices (laptops/desktops)** where **offline functionality is not
  required**.
  - _Open question (Q-STACK):_ native vs. cross-platform (Flutter/React Native);
    this is a planning decision but shapes almost everything.

## Usability — field-first (FR-UX)

- **FR-UX-1** — All features must use a **user-friendly interface** with clear
  navigation and intuitive controls — **especially field features**, where the
  user has limited time/attention and may be **wearing gloves**.
- **FR-UX-2** — The client presents a **persistent app shell**: a **bottom
  navigation** across the primary areas (apiaries, activities, journeys, todos,
  assistant), a header with the screen title, a **sync-status indicator**, and
  account access, plus a **contextual quick-add** (FAB) for the active area.
  - _Prototype:_ Melargil app shell (see
    [`docs/design/prototype.md`](../docs/design/prototype.md)).

## Accessibility (FR-AX)

- **FR-AX-1** — Design with **accessibility** in mind: screen-reader support,
  keyboard navigation, and other accessibility features so the app is usable by
  everyone, including users with disabilities.
  - _Target standard:_ **WCAG 2.2 AA** (`D-18`).
