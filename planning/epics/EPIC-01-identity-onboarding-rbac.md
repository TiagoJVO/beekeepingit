# EPIC-01 — Identity, Onboarding & RBAC

- **Milestone:** M0→M1
- **Phase:** PWA
- **Labels:** type/epic, area/auth-identity, area/rbac, area/org-tenancy
- **Requirements:** FR-ONB-1, FR-ONB-2, FR-ONB-3, FR-AU-1, FR-TEN-1, FR-TEN-2, NFR-ROL-1, NFR-SEC-1
- **Depends on:** EPIC-00
- **Spikes:** none
- **Summary:** Stand up Keycloak-backed OIDC login and the onboarding flow (profile → organization → invitations), then enforce role-based and organization-scoped access control across the backend. Establishes the identity and tenancy foundation every other domain epic builds on.

## Stories

### Task Keycloak realm/client + OIDC login in client (M0)
- **Labels:** type/task, area/auth-identity, priority/critical
- **Requirements:** NFR-SEC-1, FR-TEN-1
- **Milestone:** M0
- **Depends on:** EPIC-00
- **Acceptance criteria:**
  - [ ] A Keycloak realm and client are configured for the platform with `admin` and `user` realm roles defined.
  - [ ] The Flutter PWA performs the OIDC web redirect login flow and obtains valid access/refresh tokens.
  - [ ] Backend services validate the issued JWTs via JWKS and reject invalid/expired/forged tokens.
  - [ ] Logout clears the local session and tokens.
  - [ ] Token refresh works without forcing a full re-login within the configured session lifetime.
- **Notes:** Per D-7 (Keycloak self-hosted, OIDC). Offline login is explicitly a native-phase concern (Q-AUTH) and out of scope here. Reuses the JWT middleware from EPIC-00.

### Feature User profile creation + enforce completion (FR-ONB-1)
- **Labels:** type/feature, area/auth-identity, area/org-tenancy, priority/high
- **Requirements:** FR-ONB-1, FR-TEN-1
- **Milestone:** M1
- **Depends on:** EPIC-01/Keycloak realm/client + OIDC login
- **Acceptance criteria:**
  - [ ] On first login a user is prompted to create a profile capturing at least name and email.
  - [ ] Required profile fields are validated, and the profile cannot be submitted while incomplete.
  - [ ] A user with an incomplete profile is blocked from accessing main features and routed back to profile completion.
  - [ ] Once the profile is complete, the user proceeds to the next onboarding step (organization).
  - [ ] Creating or updating a profile is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] The profile can be revisited and edited after onboarding.
- **Notes:** History recording integrates with EPIC-07 (FR-HIS-1). Email may be sourced from the Keycloak token; confirm field set in onboarding detail.

### Feature Organization creation + enforce before app access (FR-ONB-2)
- **Labels:** type/feature, area/org-tenancy, priority/high
- **Requirements:** FR-ONB-2, FR-TEN-2, NFR-ROL-1
- **Milestone:** M1
- **Depends on:** EPIC-01/User profile creation + enforce completion
- **Acceptance criteria:**
  - [ ] After completing their profile, a user without an organization is prompted to create one (name, address; some fields optional).
  - [ ] Required organization fields are validated before the organization can be created.
  - [ ] A user with no organization membership is blocked from viewing apiaries/main features until they create or join one.
  - [ ] The user who creates the organization is automatically assigned the `admin` role for that organization (D-3).
  - [ ] Creating or updating an organization is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] The newly created organization becomes the active tenant context for subsequent requests.
- **Notes:** Per D-3 (org creator = admin). Tenancy interpretation per FR-TEN-2 / Q-TEN (organization-level isolation). History via EPIC-07.

### Feature Org membership & email invitations; org creator = admin (FR-ONB-3, D-3)
- **Labels:** type/feature, area/org-tenancy, area/rbac, priority/high
- **Requirements:** FR-ONB-3, FR-TEN-2, NFR-ROL-1
- **Milestone:** M1
- **Depends on:** EPIC-01/Organization creation + enforce before app access
- **Acceptance criteria:**
  - [ ] An organization admin can invite a person by email to join the existing organization.
  - [ ] An invited user who logs in (after profile completion) is joined to the inviting organization rather than prompted to create a new one.
  - [ ] A user can belong to an organization with a role (`admin` or `user`), and membership is enforced for data access.
  - [ ] Invitation state (e.g. pending vs. accepted) is visible to the admin.
  - [ ] Inviting a member, accepting an invitation, and removing a member are recorded in change history with actor + timestamp (FR-HIS-1).
- **Notes:** Per D-3. Invitation expiry, re-invite, removing members, and transferring admin remain open detail (D-3 "still open" + FR-ONB-3 note) — implement the core invite/join now and flag the rest. History via EPIC-07.

### Feature Roles & permissions (admin/user) + org-scoped authorization middleware (NFR-ROL-1, FR-TEN)
- **Labels:** type/feature, area/rbac, area/org-tenancy, area/security, priority/critical
- **Requirements:** NFR-ROL-1, FR-TEN-1, FR-TEN-2, NFR-SEC-1
- **Milestone:** M1
- **Depends on:** EPIC-01/Keycloak realm/client + OIDC login, EPIC-01/Org membership & email invitations
- **Acceptance criteria:**
  - [ ] Every authenticated user resolves to a role (`admin` or `user`) within their organization context.
  - [ ] A shared backend authorization middleware enforces both role and `organization_id` scope on protected endpoints.
  - [ ] Requests for resources outside the caller's organization are denied (403/404) and the denial is logged.
  - [ ] Admin-only operations are rejected for non-admin users.
  - [ ] Authorization decisions are covered by automated tests including cross-organization access attempts (NFR-TST).
- **Notes:** Per NFR-ROL-1 and FR-TEN. Exact admin-vs-user capability split is partly open (Q-ROLE) — enforce the role boundary now; fine-grained capabilities can extend later (OpenFGA/Keto noted in tech-stack.md as future). Builds on the EPIC-00 JWT middleware.

### Feature Account settings: change password, update profile (FR-AU-1)
- **Labels:** type/feature, area/auth-identity, priority/medium
- **Requirements:** FR-AU-1, NFR-SEC-1
- **Milestone:** M1
- **Depends on:** EPIC-01/User profile creation + enforce completion
- **Acceptance criteria:**
  - [ ] A user can update their profile information from an account settings screen.
  - [ ] A user can change their password (delegated to Keycloak's password flow) and is required to confirm the new password.
  - [ ] Invalid password changes (e.g. policy violation, wrong current password) surface a clear error and do not change state.
  - [ ] Updating profile information is recorded in change history with actor + timestamp (FR-HIS-1).
  - [ ] Subscription management is intentionally absent in v1 (everything free) per D-4, with no billing UI shown.
- **Notes:** FR-AU-1 mentions subscription management "if applicable" — deferred per D-4 (EPIC-90). History via EPIC-07.

### Task Tenancy enforcement (organization_id scoping; optional RLS) (FR-TEN-2)
- **Labels:** type/task, area/org-tenancy, area/security, priority/critical
- **Requirements:** FR-TEN-2, NFR-SEC-1
- **Milestone:** M1
- **Depends on:** EPIC-01/Roles & permissions + org-scoped authorization middleware
- **Acceptance criteria:**
  - [ ] Every owned row (apiary, activity, journey, and other org-owned entities) carries an `organization_id`.
  - [ ] All read and write queries are scoped by the caller's `organization_id` so data from other organizations is never returned.
  - [ ] A tenancy context is propagated from the validated token through the service layer to the data layer.
  - [ ] Optional Postgres RLS is either enabled or explicitly documented as a deferred defense-in-depth layer with a rationale.
  - [ ] Automated tests assert that a user in organization A cannot read or modify organization B's data (NFR-TST).
- **Notes:** Per FR-TEN-2 and tech-stack.md (Data/tenancy). RLS is "optional" in the requirement — record the decision either way. Activity per-user attribution is owned by EPIC-03 (FR-TEN-2 last clause).
