# EPIC-09 — Import/Export

- **Milestone:** M3
- **Phase:** PWA
- **Labels:** type/epic, area/import-export
- **Requirements:** FR-IE-1, FR-IE-2, NFR-CMP-1, NFR-TST-1
- **Depends on:** EPIC-02, EPIC-03, EPIC-04
- **Spikes:** none
- **Summary:** Export apiaries, activities, and journeys to a common format (CSV/JSON) for backup or analysis, and import them back with well-defined merge-vs-replace, ID-handling, and de-duplication semantics. Ties into the GDPR data-export obligation so a user's organization data can be extracted on request.

## Stories

### [Feature] Export apiaries/activities/journeys (CSV/JSON)
- **Labels:** type/feature, area/import-export, priority/high
- **Requirements:** FR-IE-1, FR-TEN-2
- **Milestone:** M3
- **Depends on:** EPIC-02 (Apiaries), EPIC-03 (Activities), EPIC-04 (Journeys)
- **Acceptance criteria:**
  - [ ] A user can export apiaries, activities, and journeys for their organization in CSV and in JSON (FR-IE-1)
  - [ ] The export contains only data belonging to the user's organization, enforced server-side (FR-TEN-2)
  - [ ] Per-type activity attributes (JSONB) are represented losslessly in the export so an exported-then-imported activity reproduces its attributes (D-2)
  - [ ] The export format and schema (columns/fields, types, encoding) are documented so the output is consumable by external analysis tools
  - [ ] Exporting reflects the current synced server state and includes records captured offline once they have synced (EPIC-06)
  - [ ] The export path has automated tests asserting record counts and field fidelity for both CSV and JSON (NFR-TST-1)
- **Notes:** CSV/JSON export is explicitly in v1 scope per D-4. Activity attributes are JSONB per D-2/D-6. Export of activities tied to users may include PII — see Q-EXPORT-PII and the GDPR tie-in story.

### [Feature] Import (CSV/JSON): merge vs replace, ID handling, dedupe
- **Labels:** type/feature, area/import-export, area/history-audit, priority/high
- **Requirements:** FR-IE-2, FR-HIS-1
- **Milestone:** M3
- **Depends on:** EPIC-09 (Export — shared format/schema), EPIC-02, EPIC-03, EPIC-04, EPIC-07 (History)
- **Acceptance criteria:**
  - [ ] A user can import apiaries, activities, and journeys from CSV and JSON in the documented export format (FR-IE-2)
  - [ ] The user chooses an import mode — merge (add/update into existing data) vs. replace — and the selected mode is applied as defined in Q-IMP (FR-IE-2)
  - [ ] ID handling is explicit per Q-IMP: the system either preserves source IDs or remaps them, and the chosen rule is applied consistently across apiaries, activities, and journeys (relationships stay intact)
  - [ ] Duplicate/conflict handling is defined per Q-IMP (e.g. detect duplicates by a stable key, then skip/update), and a dry-run/summary reports inserts, updates, skips, and rejected rows before or alongside committing
  - [ ] Imported create/update/delete operations are recorded in entity history with actor + timestamp (FR-HIS-1)
  - [ ] Invalid rows (bad types, missing required fields, malformed JSONB attributes) are rejected with clear per-row errors and do not abort the whole import
  - [ ] The import path has automated tests covering merge, replace, ID-preserve vs. remap, duplicate detection, and invalid-row rejection (NFR-TST-1)
- **Notes:** Import semantics (merge vs. replace, ID preservation, duplicate/conflict handling) are governed by Q-IMP — resolve before finalizing. Import must interact correctly with sync and history (Q-IMP, Q-HIS): imported changes flow through the same history/audit path as normal edits (FR-HIS-1).

### [Task] Tie-in to GDPR data export (NFR-CMP)
- **Labels:** type/task, area/import-export, area/security, priority/medium
- **Requirements:** FR-IE-1, NFR-CMP-1
- **Milestone:** M3
- **Depends on:** EPIC-09 (Export), EPIC-14 (GDPR data export/erasure)
- **Acceptance criteria:**
  - [ ] The export capability satisfies the GDPR data-export (data-portability) path for an organization's data, in a documented machine-readable format (NFR-CMP-1, FR-IE-1)
  - [ ] The export's handling of activity records tied to users (PII) is confirmed against GDPR before release, and any disallowed fields are excluded or minimized (Q-EXPORT-PII)
  - [ ] The GDPR export path is reachable/coordinated through the EPIC-14 GDPR mechanisms (data export/erasure) rather than duplicating logic
  - [ ] Who may trigger a full-organization export (e.g. org admin) is enforced via RBAC (NFR-ROL-1)
  - [ ] The GDPR-export behavior is covered by an automated test asserting completeness of a subject's/organization's exported data (NFR-TST-1)
- **Notes:** GDPR applies (Portugal/EU) per NFR-CMP-1 / Q-CMP; the heavy GDPR machinery (export/erasure, consent, EU residency) lives in EPIC-14 and this story is the import/export tie-in. PII concern tracked as Q-EXPORT-PII.
