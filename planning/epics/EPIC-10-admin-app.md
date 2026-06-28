# EPIC-10 — Admin App (web)

- **Milestone:** M3
- **Phase:** PWA
- **Labels:** type/epic, area/admin-app
- **Requirements:** NFR-ROL-1, NFR-ROL-2, NFR-TST-1
- **Depends on:** EPIC-01
- **Spikes:** none
- **Summary:** A separate web-only React admin application (online-only, no offline support) for organization management, member management, and role/permission administration. Includes a deferred placeholder hook for quotas/rate-limits (EPIC-91) without building quota enforcement in v1.

## Stories

### [Task] React admin scaffold + Keycloak auth (online-only)
- **Labels:** type/task, area/admin-app, area/auth-identity, priority/high
- **Requirements:** NFR-ROL-2, NFR-SEC-1
- **Milestone:** M3
- **Depends on:** EPIC-01 (Keycloak realm/client, roles)
- **Acceptance criteria:**
  - [ ] A React + TypeScript admin web app builds and runs as a browser-only application with no offline support (NFR-ROL-2, D-5)
  - [ ] Admin users authenticate via Keycloak (OIDC) using the existing realm/client from EPIC-01 (D-7)
  - [ ] Only users with the admin role can access the admin app; non-admin users are denied with a clear message (NFR-ROL-1)
  - [ ] All admin API calls send a valid Keycloak token and are rejected server-side when unauthenticated/expired (NFR-SEC-1)
  - [ ] The app shares the platform's project conventions (lint/format/build) from EPIC-00 and is wired into CI
  - [ ] The auth/guarding behavior (admin allowed, non-admin denied) is covered by automated tests (NFR-TST-1)
- **Notes:** Web/React, online-only per NFR-ROL-2 and D-5. Auth via Keycloak per D-7. Admin app is explicitly kept in v1 scope (not deferred) per D-4. Build tooling (Vite, optional Refine/React-Admin) per tech-stack.md.

### [Feature] Organization management
- **Labels:** type/feature, area/admin-app, area/org-tenancy, area/history-audit, priority/high
- **Requirements:** NFR-ROL-2, FR-TEN-2, FR-HIS-1
- **Milestone:** M3
- **Depends on:** EPIC-10 (admin scaffold), EPIC-01 (organizations)
- **Acceptance criteria:**
  - [ ] An admin can view and edit organization details (name, address, and other relevant fields) from the admin app (NFR-ROL-2, FR-ONB-2)
  - [ ] An admin can only manage the organization(s) they administer; cross-organization access is prevented (FR-TEN-2)
  - [ ] Create/edit/delete of organization records is recorded in entity history with actor + timestamp (FR-HIS-1)
  - [ ] Validation errors (e.g. required fields) are surfaced clearly and block invalid saves
  - [ ] Organization management actions are covered by automated tests (NFR-TST-1)
- **Notes:** Admin scope (per-org vs. system-wide) is open under Q-ROLE — default to organization-scoped admin consistent with D-3 (org creator = admin). Org model owned by EPIC-01.

### [Feature] Member management (invite/remove)
- **Labels:** type/feature, area/admin-app, area/org-tenancy, area/history-audit, priority/high
- **Requirements:** NFR-ROL-2, NFR-ROL-1, FR-HIS-1
- **Milestone:** M3
- **Depends on:** EPIC-10 (admin scaffold), EPIC-01 (membership & email invitations)
- **Acceptance criteria:**
  - [ ] An admin can view the members of their organization in the admin app (NFR-ROL-2)
  - [ ] An admin can invite a new member by email; the invited user joins the existing organization (FR-ONB-3, D-3)
  - [ ] An admin can remove a member, and the removed member loses access to the organization's data (NFR-ROL-1, FR-TEN-2)
  - [ ] Invite and remove actions are recorded in entity history with actor + timestamp (FR-HIS-1)
  - [ ] Only admins can invite/remove members; a non-admin attempting the action is denied (NFR-ROL-1)
  - [ ] Member invite/remove flows are covered by automated tests (NFR-TST-1)
- **Notes:** Email-invitation model and org-creator-as-admin per D-3 / FR-ONB-3. Membership/invitation logic is owned by EPIC-01; this story is the admin-app surface for it. Invite expiry/re-invite/admin-transfer remain open (D-3) and are not required here.

### [Feature] Roles & permissions management
- **Labels:** type/feature, area/admin-app, area/rbac, area/history-audit, priority/high
- **Requirements:** NFR-ROL-1, NFR-ROL-2, FR-HIS-1
- **Milestone:** M3
- **Depends on:** EPIC-10 (admin scaffold), EPIC-01 (roles & permissions)
- **Acceptance criteria:**
  - [ ] An admin can assign and unassign roles to users in their organization (admin/user, extensible to more roles later) (NFR-ROL-1)
  - [ ] An admin can view the permissions associated with each role (NFR-ROL-1)
  - [ ] Role/permission changes take effect on the target user's next authorized request and are enforced server-side (NFR-ROL-1)
  - [ ] Role assignment/permission changes are recorded in entity history with actor + timestamp (FR-HIS-1)
  - [ ] Only admins can manage roles/permissions; non-admins are denied (NFR-ROL-1)
  - [ ] Role/permission management is covered by automated tests, including the enforced-on-next-request behavior (NFR-TST-1)
- **Notes:** RBAC model (roles → permissions, initial admin/user) per NFR-ROL-1; exact admin-vs-user capabilities open under Q-ROLE. Underlying roles/permissions owned by EPIC-01 (Keycloak realm roles + app-level checks, D-7).

### [Task] Placeholder hooks for quotas/rate-limits (deferred — EPIC-91)
- **Labels:** type/task, area/admin-app, priority/low
- **Requirements:** NFR-RL-1, NFR-ROL-2
- **Milestone:** M3
- **Depends on:** EPIC-10 (admin scaffold)
- **Acceptance criteria:**
  - [ ] A clearly-marked placeholder/seam exists in the admin app where quota and rate-limit management will later live (NFR-ROL-2)
  - [ ] No quota or rate-limit enforcement is implemented and nothing is enforced against users in v1 (D-4)
  - [ ] The placeholder is disabled/hidden from end users (e.g. behind a feature flag or a "coming later" state) so it ships inert
  - [ ] The seam references EPIC-91 so the deferred work is traceable, without pulling any quota logic into v1
- **Notes:** Quotas/rate-limits are deferred out of v1 per D-4; keep only a design seam (NFR-RL-1 mechanism boundary), do not build quotas. Deferred work tracked as EPIC-91. This is intentionally a stub, so no functional test is required beyond confirming it ships inert.
