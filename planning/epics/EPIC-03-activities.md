# EPIC-03 — Activities

- **Milestone:** M1
- **Phase:** PWA
- **Labels:** type/epic, area/activities, area/offline-sync
- **Requirements:** FR-AC-1, FR-AC-2, FR-AC-3, FR-AC-4, FR-AC-5, FR-AC-6, FR-TEN-2
- **Depends on:** EPIC-02
- **Spikes:** none
- **Summary:** Model typed activities with per-type attributes (JSONB), including the hive-count attribute, and deliver add/edit/delete plus filterable activity lists at both the apiary and all-apiaries level, with each activity attributed to the user who performed it.

## Stories

### Feature Activity type model + per-type attributes (JSONB) incl. hive-count attr (FR-AC-1, D-2)
- **Labels:** type/feature, area/activities, area/offline-sync, priority/critical
- **Requirements:** FR-AC-1, FR-TEN-2
- **Milestone:** M1
- **Depends on:** EPIC-02
- **Acceptance criteria:**
  - [ ] Activities have a type, and each type defines its own attribute set, modeled via a typed `activities` table plus a JSONB attribute bag.
  - [ ] The initial types exist with their attributes: Honey harvest (date, amount of honey, number of hives harvested, notes), Feeding (date, type of feed, amount of feed, notes), Treatment (date, type of treatment, notes), Generic (date, notes).
  - [ ] Harvest captures a "number of hives harvested" attribute; treatment/feeding may optionally capture a hives-affected count (D-2).
  - [ ] Per-type attributes are validated server-side against the selected type's schema, rejecting unknown or malformed attributes.
  - [ ] The type/attribute model is extensible so new types can be added later without schema changes to the attribute bag.
  - [ ] Activities are recorded at the apiary level and carry the owning `organization_id` (FR-TEN-2).
- **Notes:** Per D-2 (hive count as activity attribute; no hive entities) and tech-stack.md (JSONB attribute bag with service-side validation). The hive-count attribute feeds journey aggregation FR-JO-1 (EPIC-04).

### Feature Add activity (select type, fill attributes) (FR-AC-2)
- **Labels:** type/feature, area/activities, area/offline-sync, priority/high
- **Requirements:** FR-AC-2, FR-TEN-2
- **Milestone:** M1
- **Depends on:** EPIC-03/Activity type model + per-type attributes
- **Acceptance criteria:**
  - [ ] A user can add an activity to an apiary by selecting the activity type.
  - [ ] The attribute form adapts to the selected type, showing only that type's relevant fields.
  - [ ] Required attributes are validated before the activity can be saved.
  - [ ] The created activity is associated with its apiary and attributed to the creating user (FR-TEN-2).
  - [ ] Creating an activity is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] Adding an activity works offline (queued locally) and reconciles on sync.
- **Notes:** Offline behavior per FR-OF-1 / Q-SYNC. Per-user attribution detailed in the dedicated story below (FR-TEN-2). History via EPIC-07.

### Feature Edit activity (FR-AC-3)
- **Labels:** type/feature, area/activities, area/offline-sync, priority/high
- **Requirements:** FR-AC-3
- **Milestone:** M1
- **Depends on:** EPIC-03/Add activity (select type, fill attributes)
- **Acceptance criteria:**
  - [ ] A user can edit an existing activity's attributes.
  - [ ] The edit form reflects the activity's current type and attribute values.
  - [ ] Edited attributes are validated against the type's schema before saving.
  - [ ] Editing an activity is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] Editing works offline (queued locally) and reconciles on sync under last-write-wins.
- **Notes:** Offline behavior per FR-OF-1 / Q-SYNC. History via EPIC-07.

### Feature Delete activity (FR-AC-4)
- **Labels:** type/feature, area/activities, area/offline-sync, priority/high
- **Requirements:** FR-AC-4
- **Milestone:** M1
- **Depends on:** EPIC-03/Add activity (select type, fill attributes)
- **Acceptance criteria:**
  - [ ] A user can delete an activity, with a confirmation step to prevent accidental deletion.
  - [ ] The deleted activity no longer appears in apiary or all-apiaries lists.
  - [ ] Deleting an activity is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] Deletion works offline using tombstones and propagates the delete on sync.
- **Notes:** Offline behavior per FR-OF-1 / Q-SYNC (tombstones for deletes). History via EPIC-07.

### Feature Apiary activity list + filters (type, date range) (FR-AC-5)
- **Labels:** type/feature, area/activities, area/offline-sync, priority/medium
- **Requirements:** FR-AC-5
- **Milestone:** M1
- **Depends on:** EPIC-03/Add activity (select type, fill attributes), EPIC-02/Apiary detail page incl. hive count
- **Acceptance criteria:**
  - [ ] The apiary detail page lists all activities for that apiary.
  - [ ] The list can be filtered by activity type.
  - [ ] The list can be filtered by date range.
  - [ ] Type and date-range filters can be combined and the empty/no-results state is handled.
  - [ ] The list works offline over the locally synced activity set.
- **Notes:** Renders on the apiary detail page from EPIC-02 (FR-AP-7). Offline behavior per FR-OF-1.

### Feature All-apiaries activity list + filters (FR-AC-6)
- **Labels:** type/feature, area/activities, area/offline-sync, priority/medium
- **Requirements:** FR-AC-6, FR-TEN-2
- **Milestone:** M1
- **Depends on:** EPIC-03/Add activity (select type, fill attributes)
- **Acceptance criteria:**
  - [ ] The main activities page lists activities across all apiaries in the user's organization.
  - [ ] The list can be filtered by activity type.
  - [ ] The list can be filtered by date range.
  - [ ] Results are scoped to the caller's organization only (FR-TEN-2) and never include other organizations' activities.
  - [ ] Combined filters work and the empty/no-results state is handled.
  - [ ] The list works offline over the locally synced activity set.
- **Notes:** Per D-2, activities are per-apiary; hive counts are attributes, not separate hive records. Offline behavior per FR-OF-1.

### Feature Per-user attribution of activities (FR-TEN-2)
- **Labels:** type/feature, area/activities, area/org-tenancy, priority/high
- **Requirements:** FR-TEN-2
- **Milestone:** M1
- **Depends on:** EPIC-03/Add activity (select type, fill attributes), EPIC-01/Tenancy enforcement
- **Acceptance criteria:**
  - [ ] Each activity records the user who performed it, in addition to the owning organization.
  - [ ] The performing user is displayed wherever an activity is shown (lists and detail).
  - [ ] All users in the organization can view every activity (shared org data), while attribution remains visible per activity (FR-TEN-2).
  - [ ] The recorded performer is derived from the authenticated user and cannot be spoofed by the client.
  - [ ] Attribution is preserved across offline creation and subsequent sync.
- **Notes:** Per FR-TEN-2 — organization is the unit of ownership and shared, but each activity is attributed to its performer. This is distinct from FR-HIS-1 audit history (who changed a record), which is owned by EPIC-07. Offline behavior per FR-OF-1.
