# EPIC-04 — Journeys

- **Milestone:** M2
- **Phase:** PWA
- **Labels:** type/epic, area/journeys
- **Requirements:** FR-JO-1, FR-JO-2, FR-JO-3, FR-JO-4, NFR-TST-1
- **Depends on:** EPIC-02, EPIC-03
- **Spikes:** none
- **Summary:** Seasonal aggregation of work across apiaries — plan a journey (which apiaries to visit and what to do), then track and view aggregated statistics (apiaries visited, hives harvested, honey collected, what is still missing). Builds on the offline-first apiary and activity data from M1.

## Stories

### [Feature] Journey planning: select apiaries + activities to perform
- **Labels:** type/feature, area/journeys, area/offline-sync, priority/high
- **Requirements:** FR-JO-4, FR-TEN-2
- **Milestone:** M2
- **Depends on:** EPIC-02 (Apiary CRUD), EPIC-03 (Activity type model)
- **Acceptance criteria:**
  - [ ] A user can create a journey by selecting the apiaries to be visited and the activities to be performed at each apiary, or for all apiaries (FR-JO-4)
  - [ ] The journey is scoped to the user's organization and is visible to all members of that organization (FR-TEN-2)
  - [ ] A planned journey persists a plan (intended apiaries + intended activity types) that the statistics view later compares against actuals
  - [ ] Creating, editing, and deleting a journey records the change in the entity history (actor + timestamp) (FR-HIS-1)
  - [ ] Journey planning works fully offline: a journey created or edited while offline is queued and syncs when connectivity returns
- **Notes:** The planned-vs-actual model needed for "how much is missing" is governed by Q-JOUR — resolve before finalizing the plan schema. Activities stay at the apiary level per D-2 (no hive entities).

### [Task] Activity↔journey attribution model
- **Labels:** type/task, area/journeys, area/activities, area/offline-sync, priority/high
- **Requirements:** FR-JO-1, FR-JO-4
- **Milestone:** M2
- **Depends on:** EPIC-03 (Add/Edit activity)
- **Acceptance criteria:**
  - [ ] Executed activities can be attributed to a journey using the model resolved in Q-JOUR (manual link and/or auto-match by apiary + type + date window)
  - [ ] An activity attributed to a journey can be detached/re-attributed, and the resulting statistics recompute deterministically
  - [ ] Attribution is the basis for "planned vs. actual": planned items with no matching executed activity are reported as missing (FR-JO-1)
  - [ ] An activity belongs to at most one journey at a time, and the rule is enforced consistently across offline edits and sync
  - [ ] Changing a journey attribution is recorded in entity history (actor + timestamp) (FR-HIS-1)
  - [ ] Attribution logic has unit tests covering manual link, auto-match hit, auto-match miss, and re-attribution (NFR-TST-1)
- **Notes:** Q-JOUR is the open question that selects the attribution mechanism (manual vs. auto-match). Offline behavior: attribution can be set offline; conflicting attributions across users are resolved by the EPIC-06 server-authoritative last-write-wins policy (Q-SYNC), with conflicts written to the conflict log.

### [Feature] Journeys list + filters (date range, activity type)
- **Labels:** type/feature, area/journeys, area/offline-sync, priority/medium
- **Requirements:** FR-JO-2
- **Milestone:** M2
- **Depends on:** EPIC-04 (Journey planning)
- **Acceptance criteria:**
  - [ ] The main journeys page lists all journeys for the organization (FR-JO-2)
  - [ ] The list is filterable by date range (FR-JO-2)
  - [ ] The list is filterable by activity type (FR-JO-2)
  - [ ] Date-range and activity-type filters can be combined, and an empty result set shows a clear empty state
  - [ ] The list renders from the local offline store and shows data captured while offline before it has synced
- **Notes:** Offline behavior: list and filters operate against the on-device store (EPIC-06), so they work with no connectivity.

### [Feature] Journey detail: apiaries visited, activities, stats
- **Labels:** type/feature, area/journeys, area/offline-sync, priority/medium
- **Requirements:** FR-JO-3
- **Milestone:** M2
- **Depends on:** EPIC-04 (Journey planning, Attribution model)
- **Acceptance criteria:**
  - [ ] The journey detail page lists the apiaries visited in the journey (FR-JO-3)
  - [ ] For each apiary, the detail page lists the activities performed there as attributed to the journey (FR-JO-3)
  - [ ] The detail page shows the aggregated statistics for that journey (FR-JO-3)
  - [ ] Planned items not yet executed are clearly distinguished from completed items (planned vs. actual)
  - [ ] The detail page renders offline from the local store
- **Notes:** Reuses the aggregation from the statistics story. Offline behavior per EPIC-06.

### [Feature] Journey statistics/aggregation (apiaries visited, hives harvested, honey collected, missing)
- **Labels:** type/feature, area/journeys, area/offline-sync, priority/high
- **Requirements:** FR-JO-1
- **Milestone:** M2
- **Depends on:** EPIC-04 (Attribution model), EPIC-03 (harvest hive-count attribute)
- **Acceptance criteria:**
  - [ ] Selecting a journey shows aggregated metrics: apiaries visited, hives harvested, honey collected, and how much is still missing (planned vs. done) (FR-JO-1)
  - [ ] "Hives harvested" is computed as the sum of the number-of-hives-harvested attribute across the harvest activities attributed to the journey (D-2)
  - [ ] "Honey collected" is computed as the sum of the honey-harvested amount across harvest activities attributed to the journey
  - [ ] "Missing" is computed as planned apiaries/activities minus those with a matching executed activity (FR-JO-1)
  - [ ] Aggregations recompute when activities are added, edited, deleted, attributed, or detached, and produce identical results offline and after sync
  - [ ] Aggregation logic has unit tests covering empty journey, partial completion, full completion, and the hive-count summation (NFR-TST-1)
- **Notes:** "Hives harvested = Σ hive-count attribute" per D-2. The missing/planned-vs-actual semantics depend on Q-JOUR. Offline behavior: statistics are derived locally from the on-device store (EPIC-06) and stay consistent through sync.
