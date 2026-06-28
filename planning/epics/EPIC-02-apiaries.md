# EPIC-02 — Apiaries

- **Milestone:** M1
- **Phase:** PWA
- **Labels:** type/epic, area/apiaries, area/maps-geo, area/offline-sync
- **Requirements:** FR-AP-1, FR-AP-2, FR-AP-3, FR-AP-4, FR-AP-5, FR-AP-6, FR-AP-7
- **Depends on:** EPIC-01, EPIC-06
- **Spikes:** none
- **Summary:** Deliver the apiary domain: full offline-capable CRUD, a detail page with hive count, proximity-ordered list and map views with a toggle, search, and apiary-to-apiary distance. This is the first real domain entity and the anchor for activities, journeys, and todos.

## Stories

### Feature Apiary CRUD (FR-AP-1)
- **Labels:** type/feature, area/apiaries, area/offline-sync, priority/critical
- **Requirements:** FR-AP-1, FR-TEN-2
- **Milestone:** M1
- **Depends on:** EPIC-01, EPIC-06
- **Acceptance criteria:**
  - [ ] A user can create an apiary with at least a name and location, scoped to their organization.
  - [ ] A user can read/view an apiary's details.
  - [ ] A user can update an apiary's fields and the changes persist.
  - [ ] A user can delete an apiary, with a confirmation step to prevent accidental deletion.
  - [ ] Required fields are validated on create and update, with clear errors.
  - [ ] Every create, update, and delete is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] Create/update/delete work offline (queued locally) and reconcile on sync; deletes use tombstones so they propagate.
- **Notes:** Offline behavior per FR-OF-1 and Q-SYNC (server-authoritative last-write-wins, conflict log). Apiaries are organization-owned (FR-TEN-2). History via EPIC-07; sync via EPIC-06.

### Feature Apiary detail page incl. hive count (FR-AP-7, D-2)
- **Labels:** type/feature, area/apiaries, priority/high
- **Requirements:** FR-AP-7
- **Milestone:** M1
- **Depends on:** EPIC-02/Apiary CRUD
- **Acceptance criteria:**
  - [ ] The apiary detail page shows name, location, number of hives (a count), and other relevant details.
  - [ ] The hive count is an editable numeric attribute on the apiary (not a separate hive entity) and rejects invalid values (e.g. negative).
  - [ ] Editing the hive count is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] The detail page renders correctly when optional fields are empty.
  - [ ] The detail page is reachable from both the list and map views.
- **Notes:** Per D-2 — hives are a count + activity attribute, not a separate entity (supersedes Q-HIVE/Q-GRAN). The activity list on this page is delivered by EPIC-03 (FR-AC-5). History via EPIC-07.

### Feature List ordered by proximity to user (FR-AP-2, PostGIS)
- **Labels:** type/feature, area/apiaries, area/maps-geo, area/offline-sync, priority/high
- **Requirements:** FR-AP-2, FR-AP-4
- **Milestone:** M1
- **Depends on:** EPIC-02/Apiary CRUD
- **Acceptance criteria:**
  - [ ] The apiary list orders apiaries by distance from the user's current location, closest first.
  - [ ] When location permission is granted, ordering reflects the live device location.
  - [ ] When location is unavailable or denied, the list falls back to a deterministic order (e.g. by name) with a clear indication.
  - [ ] Proximity ordering produces correct results for apiaries spread across distances (verified against known coordinates).
  - [ ] The list works offline using the locally synced apiary set and an offline distance computation.
- **Notes:** Server-side proximity uses PostGIS (D-6); offline ordering uses a local haversine computation (consistent with FR-AP-5 / Q-DIST). Offline behavior per FR-OF-1. Map provider/offline tiles are tracked in Q-MAP (relevant to FR-AP-3).

### Feature Map view: apiary markers + user location (FR-AP-3)
- **Labels:** type/feature, area/maps-geo, area/apiaries, priority/high
- **Requirements:** FR-AP-3
- **Milestone:** M1
- **Depends on:** EPIC-02/Apiary CRUD
- **Acceptance criteria:**
  - [ ] The map view renders a marker for each apiary at its stored location.
  - [ ] The map renders a distinct marker for the user's current location when available.
  - [ ] Tapping an apiary marker navigates to (or previews) that apiary's detail.
  - [ ] The map handles the empty case (no apiaries) and the permission-denied case (no user-location marker) gracefully.
  - [ ] The map renders without error on the PWA target across a reasonable number of markers (performance per Q-PERF to be confirmed).
- **Notes:** Map stack per tech-stack.md (`flutter_map` + MapLibre/OSM). Provider and offline-tile strategy are open (Q-MAP) and have licensing/cost implications — confirm before committing offline tiles.

### Feature Map/list toggle (FR-AP-4)
- **Labels:** type/feature, area/apiaries, area/maps-geo, priority/medium
- **Requirements:** FR-AP-4
- **Milestone:** M1
- **Depends on:** EPIC-02/List ordered by proximity to user, EPIC-02/Map view: apiary markers + user location
- **Acceptance criteria:**
  - [ ] The user can switch between map view and list view; both are available.
  - [ ] Switching views preserves the relevant context (e.g. current filter/selection) where applicable.
  - [ ] The active view is visually indicated.
  - [ ] The toggle is reachable with large, gloves-friendly tap targets (FR-UX) and is keyboard/screen-reader accessible (FR-AX).
- **Notes:** Field-first UX and a11y depth are owned by EPIC-11 (FR-UX-1, FR-AX-1); apply the baseline here.

### Feature Search by name/location/attributes (FR-AP-6)
- **Labels:** type/feature, area/apiaries, area/offline-sync, priority/medium
- **Requirements:** FR-AP-6
- **Milestone:** M1
- **Depends on:** EPIC-02/Apiary CRUD
- **Acceptance criteria:**
  - [ ] A user can search apiaries by name.
  - [ ] A user can search apiaries by location and by other relevant attributes.
  - [ ] Search results update responsively as the query changes and indicate when there are no matches.
  - [ ] Search is scoped to the user's organization only (FR-TEN-2).
  - [ ] Search works offline over the locally synced apiary set.
- **Notes:** Search scope (offline/online, which attributes, whether activities/journeys/todos are included) is open in Q-SEARCH — this story covers apiaries only. Offline behavior per FR-OF-1.

### Feature Distance between two apiaries — haversine offline, driving online later (FR-AP-5, Q-DIST)
- **Labels:** type/feature, area/maps-geo, area/apiaries, area/offline-sync, priority/medium
- **Requirements:** FR-AP-5
- **Milestone:** M1
- **Depends on:** EPIC-02/Apiary CRUD
- **Acceptance criteria:**
  - [ ] A user can select two apiaries and see the distance between them.
  - [ ] Straight-line (haversine) distance is computed and displayed and works fully offline.
  - [ ] The displayed distance uses a clear unit consistent with the app's locale/metric settings (km).
  - [ ] The selection mechanism for the two apiaries is clear and usable (FR-UX).
  - [ ] The result is correct for known coordinate pairs within an acceptable tolerance.
- **Notes:** Per Q-DIST recommended default — haversine offline now; optional driving distance (routing service, online-only) deferred. Whether distance from the user's current location is also shown overlaps FR-AP-2. Units per the "Units & formats" open item (kg/L, km).
