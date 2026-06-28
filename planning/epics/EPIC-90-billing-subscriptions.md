# EPIC-90 — Billing & Subscriptions

- **Milestone:** Deferred
- **Phase:** post-v1
- **Labels:** type/epic, area/rbac
- **Requirements:** FR-AU-2
- **Depends on:** EPIC-01
- **Spikes:** none
- **Summary:** **Deferred (post-v1, per D-4.)** v1 ships only the subscription/feature-toggle **enforcement mechanism** as a design seam — everything is free with no billing UI. Real billing and subscription management are deferred to a later release.

## Stories

### Task Subscription feature-toggle / enforcement mechanism (stub)
- **Labels:** type/task, area/rbac, priority/low
- **Requirements:** FR-AU-2
- **Milestone:** Deferred
- **Depends on:** EPIC-01
- **Acceptance criteria:**
  - [ ] A feature-toggle/enforcement seam exists so a capability *could* later be gated by subscription level, defaulting to **all features available to all users** (FR-AU-2).
  - [ ] The mechanism is wired without any billing logic — no payment provider, no subscription UI, no plan management.
  - [ ] A subscription-level/plan concept exists as a stub on the org/account model so future tiers can attach without a schema rewrite.
  - [ ] A note records that **full billing delivery is later** (D-4) and lists the seams to extend.
- **Notes:** Deferred per D-4 (billing/subscriptions out of v1; mechanism only). FR-AU-2 explicitly requires the mechanism to exist now while everything stays free. Admin-app placeholder hooks for this live in EPIC-10. **Suggested label:** area/billing (no billing label in labels.yml; using area/rbac as the closest access-gating area).
