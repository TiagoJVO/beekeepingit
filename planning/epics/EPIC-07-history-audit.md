# EPIC-07 — History & Audit

- **Milestone:** M1
- **Phase:** PWA
- **Labels:** type/epic, area/history-audit
- **Requirements:** FR-HIS-1, NFR-TST-1
- **Depends on:** EPIC-01, EPIC-06
- **Spikes:** none
- **Summary:** An append-only change history for every domain entity — each create, update, or delete records the acting user and a timestamp — with a per-entity history view and well-defined behavior across offline edits and sync. This is the cross-cutting audit trail the rest of the domain writes into.

## Stories

### [Task] Append-only history per entity (actor + timestamp)
- **Labels:** type/task, area/history-audit, area/offline-sync, priority/high
- **Requirements:** FR-HIS-1, FR-TEN-2
- **Milestone:** M1
- **Depends on:** EPIC-01 (auth/identity for actor), EPIC-06 (sync integration)
- **Acceptance criteria:**
  - [ ] Every create, update, and delete of any domain entity (apiary, activity, journey, todo, and future entities) writes a history record (FR-HIS-1)
  - [ ] Each history record captures the user who made the change and the timestamp of the change (FR-HIS-1)
  - [ ] History records are append-only — they cannot be edited or deleted through the application
  - [ ] History is organization-scoped consistently with the entity it describes (FR-TEN-2)
  - [ ] The history-writing mechanism is provided as a shared cross-cutting library so every service records changes uniformly (per tech-stack shared audit/history lib)
  - [ ] Automated tests assert that create/update/delete each produce exactly one correctly-attributed history record (NFR-TST-1)
- **Notes:** Actor identity comes from EPIC-01 (Keycloak/JWT + org context). Implemented as a shared lib (FR-HIS, tech-stack "Cross-cutting"). This story provides the recording capability that all create/edit/delete acceptance criteria across EPIC-02..05 reference.

### [Feature] History view per apiary/activity/journey
- **Labels:** type/feature, area/history-audit, area/offline-sync, priority/medium
- **Requirements:** FR-HIS-1
- **Milestone:** M1
- **Depends on:** EPIC-07 (Append-only history), EPIC-02 (Apiaries), EPIC-03 (Activities)
- **Acceptance criteria:**
  - [ ] A user can view the change history of a specific apiary (FR-HIS-1)
  - [ ] A user can view the change history of a specific activity (FR-HIS-1)
  - [ ] A user can view the change history of a specific journey (FR-HIS-1)
  - [ ] Each history entry displays the actor and the timestamp, ordered chronologically
  - [ ] The history view renders offline from the local store for changes that have synced to the device
- **Notes:** Visibility scope (all members vs. admin only) is open under Q-HIS. Todo history reuses the same view component (EPIC-05 records todo history). Offline behavior per EPIC-06.

### [Task] History across offline edits + sync
- **Labels:** type/task, area/history-audit, area/offline-sync, priority/high
- **Requirements:** FR-HIS-1, FR-OF-1, NFR-TST-1
- **Milestone:** M1
- **Depends on:** EPIC-07 (Append-only history), EPIC-06 (Conflict policy)
- **Acceptance criteria:**
  - [ ] Changes made while offline produce history records locally and those records sync to the server without loss (FR-HIS-1, FR-OF-1)
  - [ ] History records preserve the original change timestamp and actor through sync (not the sync time)
  - [ ] When the conflict policy resolves a concurrent edit (server-authoritative last-write-wins), the history reflects what happened without being silently overwritten, consistent with the EPIC-06 conflict log (Q-SYNC)
  - [ ] History records survive sync without duplication when the same offline change is replicated once connectivity returns
  - [ ] Automated tests cover offline create/edit → sync → history present once with correct actor/timestamp, including a conflict scenario (NFR-TST-1)
- **Notes:** Q-HIS asks specifically how history behaves across offline edits/sync. Tightly coupled to EPIC-06's conflict policy and tombstone handling — coordinate so a resolved conflict leaves a coherent audit trail.

### [Task] Retention/immutability policy
- **Labels:** type/task, area/history-audit, area/security, priority/medium
- **Requirements:** FR-HIS-1, NFR-CMP-1
- **Milestone:** M1
- **Depends on:** EPIC-07 (Append-only history)
- **Acceptance criteria:**
  - [ ] A retention period for history records is defined and documented (Q-HIS)
  - [ ] Immutability is enforced so application code paths cannot mutate or delete history records (Q-HIS)
  - [ ] The policy is reconciled with GDPR data-erasure obligations so erasure requests are handled without breaking the append-only guarantee (NFR-CMP-1)
  - [ ] Any enforced purge/anonymization after the retention period is itself recorded/auditable
  - [ ] The policy is captured in documentation that the import/export and GDPR work (EPIC-09, EPIC-14) can reference
- **Notes:** Retention period, immutability, and visibility are open under Q-HIS. GDPR erasure (NFR-CMP, owned in EPIC-14) can conflict with strict immutability — this story defines the reconciliation. Coordinates with EPIC-14 (GDPR) and EPIC-09 (data export).
