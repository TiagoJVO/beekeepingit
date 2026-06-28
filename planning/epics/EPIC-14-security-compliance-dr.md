# EPIC-14 — Security, Compliance & DR

- **Milestone:** M0 → M3
- **Phase:** cross-cutting
- **Labels:** type/epic, area/security
- **Requirements:** NFR-SEC-1, NFR-CMP-1, NFR-DR-1
- **Depends on:** EPIC-01, EPIC-13
- **Spikes:** none (the regulatory-research story below is itself a `[Spike]`)
- **Summary:** Establish the cross-cutting security baseline (secrets, TLS, input validation, OWASP protections, dependency/container scanning), GDPR compliance (export/erasure, consent, EU residency), Portuguese/EU beekeeping & honey-traceability regulatory research, and disaster recovery (Postgres backups, restore drills, RPO/RTO). This epic also provides the GDPR/consent foundation that the cloud AI assistant (EPIC-08) depends on.

## Stories

### Task Security baseline: secrets, TLS, input validation, authz, SQLi/XSS/CSRF, dependency/container scanning
- **Labels:** type/task, area/security, area/infra, priority/critical
- **Requirements:** NFR-SEC-1
- **Milestone:** M0
- **Depends on:** EPIC-13, EPIC-01
- **Acceptance criteria:**
  - [ ] **Secrets management** is in place (e.g. Kubernetes Secrets/sealed-secrets/external secrets); no secrets in source, images, or logs.
  - [ ] **TLS** terminates at the gateway/ingress and internal service traffic policy is documented (mTLS or network policy where applicable).
  - [ ] Server-side **input validation** is enforced on all client-facing endpoints; invalid input is rejected with the standard error format.
  - [ ] **SQL injection** is prevented via parameterized/typed queries (pgx + sqlc), and **XSS/CSRF** protections are applied at the client/gateway (output encoding, CSRF tokens or same-site policy as appropriate).
  - [ ] **Dependency scanning** and **container-image scanning** run in CI (wired into EPIC-13 CI/CD) and fail the build on configured severities.
  - [ ] Org-scoped **authorization** is verified by tests (a user cannot access another organization's data — ties to FR-TEN-2 / EPIC-01).
- **Notes:** NFR-SEC-1 names SQLi/XSS/CSRF explicitly. AuthN/AuthZ build on Keycloak (D-7) and the org-scoping middleware in EPIC-01. The scanning stage is executed by EPIC-13's CI/CD pipeline. Offline-auth specifics remain in Q-AUTH (owned by EPIC-01).

### Feature GDPR: data export/erasure, consent records, privacy policy, EU residency
- **Labels:** type/feature, area/security, area/import-export, priority/high
- **Requirements:** NFR-CMP-1, NFR-AI-1
- **Milestone:** M3
- **Depends on:** EPIC-01, EPIC-09
- **Acceptance criteria:**
  - [ ] A user/organization can request a **data export** of their personal/organization data in a portable format (ties into FR-IE-1 / EPIC-09).
  - [ ] A **data erasure** ("right to be forgotten") path removes or anonymizes a subject's personal data, with handling defined for append-only history (FR-HIS-1) and activity attribution.
  - [ ] **Consent records** are stored with timestamp and scope, including the explicit consent required before any cloud-AI processing (NFR-AI-1, Q-AICLOUD).
  - [ ] A **privacy policy** is surfaced in-app and versioned; consent is captured against the policy version.
  - [ ] **EU data residency** is documented and enforced for stored data and any external processor (self-hosted EU data per tech-stack.md).
  - [ ] Export of activity data tied to users is reviewed for PII exposure and limited per GDPR (Q-EXPORT-PII).
- **Notes:** GDPR applies (Portugal/EU) per Q-CMP. The consent-record mechanism is the dependency the cloud AI feature (EPIC-08, Q-AICLOUD) consumes. Export reuses the EPIC-09 export path. **Suggested label:** area/compliance (no compliance label in labels.yml; using area/security + area/import-export as closest).

### Spike Portuguese/EU beekeeping & honey-traceability regulatory research
- **Labels:** type/spike, area/security, priority/medium
- **Requirements:** NFR-CMP-1
- **Milestone:** M0
- **Depends on:** —
- **Acceptance criteria:**
  - [ ] Confirm whether **HIPAA** applies and document the rationale to **drop it** if not (Q-CMP expects it is not applicable to a beekeeping app).
  - [ ] Enumerate the concrete **Portuguese/EU beekeeping obligations** (e.g. apiary registration, treatment/medicine records) that may become real requirements.
  - [ ] Enumerate **honey/food traceability** obligations relevant to harvest records and exports.
  - [ ] Produce a short findings note mapping each confirmed obligation to candidate FR/NFR follow-ups (no implementation in this spike).
  - [ ] Flag any obligation that would change the data model (e.g. mandatory treatment fields) so it can be triaged before the relevant feature epic.
- **Notes:** Resolves Q-REG / Q-CMP (Context C-2). Time-boxed research only; outputs feed back into requirements. **Suggested label:** area/compliance (using area/security as closest available).

### Task Disaster recovery: Postgres backups, restore drills, RPO/RTO
- **Labels:** type/task, area/infra, area/security, priority/high
- **Requirements:** NFR-DR-1
- **Milestone:** M3
- **Depends on:** EPIC-13
- **Acceptance criteria:**
  - [ ] Automated **Postgres backups** run on a schedule (e.g. base backups + WAL/PITR) and are stored off the primary (e.g. MinIO/object storage).
  - [ ] A documented **restore procedure** exists and a **restore drill** successfully recovers the database to a target point.
  - [ ] **RPO and RTO targets** are defined and the drill validates they are met (Q-DR).
  - [ ] The backup **scope** is documented — what is backed up (server-side org data; on-device data treated via sync, not backup) per Q-DR.
  - [ ] Backup success/failure is monitored and alerts on failure (ties to EPIC-13 observability).
  - [ ] Restore drills are scheduled to recur (not a one-off).
- **Notes:** NFR-DR-1 requires backup/restore and fast recovery. RPO/RTO numbers and backup scope are open in Q-DR — define them as part of this story. **Suggested label:** area/dr (no DR label in labels.yml; using area/infra + area/security as closest).
