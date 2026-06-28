# EPIC-91 — Rate Limiting & Quotas

- **Milestone:** Deferred
- **Phase:** post-v1
- **Labels:** type/epic, area/infra
- **Requirements:** NFR-RL-1
- **Depends on:** EPIC-13, EPIC-10
- **Spikes:** none
- **Summary:** **Deferred (post-v1, per D-4.)** v1 keeps the rate-limit/quota **enforcement mechanism** as a design boundary only — no quota enforcement, everything free. Tiered limits, usage views, approach-limit notifications, and Admin-App management are deferred to a later release.

## Stories

### Task Rate-limit / quota enforcement mechanism (stub)
- **Labels:** type/task, area/infra, priority/low
- **Requirements:** NFR-RL-1
- **Milestone:** Deferred
- **Depends on:** EPIC-13, EPIC-10
- **Acceptance criteria:**
  - [ ] A rate-limit/quota enforcement seam exists (e.g. a gateway/middleware hook) that is **disabled/no-op by default** so everything stays free (D-4).
  - [ ] The seam is designed to later support **tiering by subscription level** (NFR-RL-1) without a rewrite, but no tiers are enforced now.
  - [ ] No usage-view UI, no approach-limit notifications, and no Admin-App quota management are built — only the boundary.
  - [ ] A note records that **full delivery is later** (D-4) and that management will be via the Admin App (NFR-ROL-2 / EPIC-10), with placeholder hooks already present in EPIC-10.
- **Notes:** Deferred per D-4 (Q-RL/Q-SUB resolved: mechanism/stubs only in v1). NFR-RL-1's tiering, usage views, notifications, and Admin-App management are later. Admin-App placeholder hooks live in EPIC-10. **Suggested label:** area/rate-limiting (no rate-limiting label in labels.yml; using area/infra as closest, since enforcement sits at the gateway/platform layer).
