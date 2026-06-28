# EPIC-06 — Offline & Sync

- **Milestone:** M0→M1
- **Phase:** cross-cutting
- **Labels:** type/epic, area/offline-sync
- **Requirements:** FR-OF-1, NFR-ARC-2, NFR-TST-1
- **Depends on:** EPIC-00, EPIC-13
- **Spikes:** SP-1
- **Summary:** The offline/sync backbone for the whole product. Picks and integrates the sync engine (SP-1), gives the client a local store that works fully offline, defines the conflict policy (server-authoritative last-write-wins + conflict log), scopes replication per organization/user, and surfaces sync status in the UI. Every domain entity rides on this slice.

## Stories

### [Spike] SP-1 — PowerSync vs ElectricSQL (incl. web/PWA persistence)
- **Labels:** type/spike, area/offline-sync, priority/critical
- **Requirements:** FR-OF-1, NFR-ARC-2
- **Milestone:** M0
- **Depends on:** EPIC-00 (Flutter app skeleton, local dev environment)
- **Acceptance criteria:**
  - [ ] PowerSync and ElectricSQL are compared head-to-head against the Flutter web SDK maturity and PWA offline persistence (wa-sqlite over IndexedDB/OPFS), including iOS PWA storage durability
  - [ ] The comparison covers conflict-handling support, self-hosting on the k8s cluster, and operational cost/complexity
  - [ ] A working throwaway prototype demonstrates create → offline edit → sync on at least one engine in the PWA
  - [ ] A recommendation resolves the D-6 sync-engine choice with documented trade-offs
  - [ ] The findings confirm or refine the default conflict policy (server-authoritative record-level last-write-wins + conflict log) for Q-SYNC
- **Notes:** Resolves the open part of D-6 (engine pick) and informs Q-SYNC. SP-1 is near-term and PWA-blocking; SP-2 (on-device LLM) is out of scope here. This is research only — no production code is committed from the spike.

### [Task] Client local store + sync integration (web SDK)
- **Labels:** type/task, area/offline-sync, priority/critical
- **Requirements:** FR-OF-1, NFR-ARC-2
- **Milestone:** M0→M1
- **Depends on:** EPIC-06 (SP-1), EPIC-00 (Flutter app skeleton)
- **Acceptance criteria:**
  - [ ] The chosen sync engine's web SDK is integrated into the Flutter PWA with a local store (wa-sqlite over IndexedDB/OPFS)
  - [ ] Reads and writes go through the local store first, so the app is fully usable with no connectivity (FR-OF-1)
  - [ ] Local writes are durable across app reload/restart while offline
  - [ ] Queued local changes replicate to PostgreSQL when connectivity returns, and server changes replicate down to the device
  - [ ] The sync integration sits behind an abstraction so the engine can be swapped without rewriting feature code (NFR-ARC-2)
  - [ ] Integration tests cover offline write → reconnect → server reflects the change, and server change → device reflects it (NFR-TST-1)
- **Notes:** This is the foundation every M1+ feature depends on. The SQLite-on-device path (native phase) and the web SDK path (PWA phase) share the same abstraction (D-6, D-10).

### [Task] Conflict policy: server-authoritative last-write-wins + conflict log
- **Labels:** type/task, area/offline-sync, priority/high
- **Requirements:** FR-OF-1, NFR-TST-1
- **Milestone:** M1
- **Depends on:** EPIC-06 (Client local store + sync integration)
- **Acceptance criteria:**
  - [ ] Conflicting concurrent edits to the same record are resolved server-authoritatively using record-level last-write-wins with server timestamps (Q-SYNC)
  - [ ] Every resolved conflict is recorded in a conflict log capturing the record, the competing versions, the winner, and the timestamp
  - [ ] Deletes are handled via tombstones so a delete does not silently lose to a concurrent edit
  - [ ] The clock/timestamp source for ordering is defined and used consistently server-side
  - [ ] Conflict resolution is consistent across all domain entities (apiaries, activities, journeys, todos) and does not corrupt entity history (FR-HIS-1)
  - [ ] Automated tests reproduce a two-client offline-edit conflict and assert the winner and a conflict-log entry (NFR-TST-1)
- **Notes:** Implements the recommended default from Q-SYNC; field-level merge is explicitly out of scope for v1 and revisited only where it hurts. Coordinates with EPIC-07 so conflict resolution and append-only history stay consistent.

### [Task] Org/user-scoped replication slice
- **Labels:** type/task, area/offline-sync, area/org-tenancy, priority/high
- **Requirements:** FR-OF-1, FR-TEN-2, NFR-SEC-1
- **Milestone:** M1
- **Depends on:** EPIC-06 (Client local store + sync integration), EPIC-01 (Tenancy enforcement)
- **Acceptance criteria:**
  - [ ] The sync engine replicates only the slice of data relevant to the signed-in user, scoped by organization (FR-TEN-2)
  - [ ] Activity ownership is preserved by also scoping per user where required, without breaking organization-wide sharing of apiaries/activities/journeys
  - [ ] A device never receives rows belonging to another organization (verified by test) (NFR-SEC-1)
  - [ ] Changing organization membership updates what replicates to a device on the next sync
  - [ ] The replication scope is enforced server-side, not only filtered on the client
- **Notes:** Aligns with the central reconciliation in the tech stack — one Postgres cluster, schema per service, sync replicates only the client-relevant org slice. Depends on tenancy scoping from EPIC-01.

### [Feature] Offline UX: sync status, queued changes, retry
- **Labels:** type/feature, area/offline-sync, priority/medium
- **Requirements:** FR-OF-1, FR-UX-1
- **Milestone:** M1
- **Depends on:** EPIC-06 (Client local store + sync integration)
- **Acceptance criteria:**
  - [ ] The UI shows a clear sync status (e.g., online/syncing/offline/up-to-date) (FR-OF-1)
  - [ ] The user can see that there are queued/unsynced local changes and roughly how many
  - [ ] A failed sync can be retried, and transient failures retry automatically with backoff
  - [ ] Sync status indicators are legible and gloves-friendly for field use (FR-UX-1)
  - [ ] The user is informed (non-blocking) when a conflict was resolved against their local edit, consistent with the conflict log
- **Notes:** The exact "synced" status vocabulary shown to the user is part of Q-SYNC. Field-first UX per FR-UX-1.
