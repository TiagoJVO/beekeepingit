# Web admin app — architecture (as-built)

> **Status:** As-built for the M7 scaffold ([#72](https://github.com/TiagoJVO/beekeepingit/issues/72))
> plus organization management ([#73](https://github.com/TiagoJVO/beekeepingit/issues/73)),
> member management ([#74](https://github.com/TiagoJVO/beekeepingit/issues/74)) and roles &
> permissions management ([#75](https://github.com/TiagoJVO/beekeepingit/issues/75)).
> Covers the app shell, OIDC auth, the admin-role guard, and the admin screens (org view/edit;
> member view/invite/remove/re-role; role-capabilities reference).

**Requirements:** NFR-ROL-1 (RBAC), NFR-ROL-2 (separate online-only admin app), FR-ONB-2 (org
details), FR-ONB-3 (membership & invitations), FR-TEN-2 (org-scoped ownership + optimistic
concurrency), FR-HIS-1 (entity history), NFR-SEC-1 (authenticated/authorized API access),
NFR-TST-1 (automated tests), NFR-I18N (EN/PT)
**Decisions:** [D-5](../../requirements/decisions.md#d-5) (React + TS admin, online-only),
[D-7](../../requirements/decisions.md#d-7) (Authentik behind a provider-agnostic OIDC boundary)
**Builds on:** [auth.md](auth.md) (§3.2 admin client, §3.4 token, §5.3 roles),
[oidc-integration.md](oidc-integration.md) (frozen OIDC contract), [ADR-0016](../adr/0016-replace-keycloak-with-authentik.md)

---

## 1. What it is

A **React + TypeScript** browser SPA (`admin/`) for organization administration — the
**canonical management surface** for members, roles and invitations (auth.md §5.3). It is
**online-only** (NFR-ROL-2, D-5): deliberately **no** offline support, service worker, or
PowerSync — that stack belongs to the Flutter field client, not here.

| Concern      | Choice                  | Why                                                     |
| ------------ | ----------------------- | ------------------------------------------------------- |
| Build tool   | Vite                    | tech-stack.md (Admin web app)                           |
| Auth         | `react-oidc-context`    | Generic, discovery-driven OIDC; provider-agnostic (D-7) |
| Server state | TanStack Query          | Async role/data fetching with loading/error states      |
| i18n         | react-i18next (EN/PT)   | Strings externalized (NFR-I18N)                         |
| Tests        | Vitest + RTL + jest-axe | Behaviour- and accessibility-focused (NFR-TST-1)        |

No CRUD-scaffolding framework (Refine / React-Admin) is adopted yet — there are no screens
to scaffold at this stage (YAGNI); tech-stack.md keeps that option open.

## 2. Authentication (OIDC, provider-agnostic)

Login is **Authorization Code + PKCE** against the platform OIDC provider, driven entirely by
**discovery**: the only provider knob is the **issuer** (`VITE_OIDC_ISSUER`); every endpoint
(authorize / token / JWKS / end-session) is read from the issuer's
`.well-known/openid-configuration`. Swapping the IdP is just changing the issuer
(oidc-integration.md §1). The app is a **public client** — no client secret (auth.md §3.2).

- **Client id** — `VITE_OIDC_CLIENT_ID`, defaulting to `beekeepingit-admin` (the admin
  client in auth.md §3.2). It must match a client provisioned in the IdP; blueprint
  provisioning of that client is an **infra concern**, not app code.
- **Token storage** — access/refresh tokens in `localStorage` via oidc-client-ts
  (`WebStorageStateStore`); silent renew keeps the access token fresh.
- **Account & password** — **out of scope, stays at the IdP** (D-7). The shell links out to
  `VITE_ACCOUNT_URL`; the app never implements account/password flows.

## 3. Authorization — the admin-role guard (NFR-ROL-1)

The `admin`/`user` role is **org-scoped and resolved server-side** from
`organizations.memberships` — it is **deliberately not an OIDC token claim** (auth.md §3.4,
ADR-0004). So the guard does not decode the token for a role; instead:

1. After login the typed API client calls **`GET /v1/organizations/me`** with the bearer
   token. The response carries the caller's own membership `role`
   (`contracts/openapi/organizations.openapi.yaml`).
2. **Only `role === "admin"` reaches the app shell.** A non-admin (`user`, or any future
   non-admin role) gets a clear **"admin access required"** message. A `404` (no active
   membership) gets a **"join an organization first"** message. A `401`/network error gets a
   retryable error screen.

```text
OIDC session ──▶ GET /v1/organizations/me (Bearer) ──▶ role?
                                                        ├─ admin  ▶ App shell
                                                        ├─ user   ▶ Access denied (not admin)
                                                        └─ 404    ▶ Access denied (no org)
```

Decision logic lives in `src/auth/access.ts` as a **pure function** (`decideAccess`) mapping
auth + role-query state to a view — exhaustively unit-tested. `AdminGuard` wires live hooks
(`useAuth`, `useMembershipRole`) into it and is integration-tested for the headline cases
(admin allowed, non-admin denied) with React Testing Library.

## 4. Authenticated API access (NFR-SEC-1)

`src/api/client.ts` is a minimal typed client: every request attaches
`Authorization: Bearer <access_token>` and maps `401/403/404`/network failures to a typed
`ApiError`. The server remains authoritative — it rejects unauthenticated/expired tokens
(`401`) and non-admin callers (`403`) regardless of anything the client does; the client-side
guard is a UX layer, not a security boundary.

## 5. Organization management (view/edit) — #73

The first administrative screen (`src/components/OrganizationSettings.tsx`, rendered inside the
admin `AppShell`) lets an admin **view and edit their organization's name and address**
(NFR-ROL-2, FR-ONB-2). It is deliberately scoped to the caller's **own** org — there is no
cross-org switcher — and relies on the server to re-enforce admin-only + org-scope (auth.md
§5.3) regardless of the client.

**Read → edit → write, with optimistic concurrency (FR-TEN-2):**

```text
GET /v1/organizations/me ──▶ { org, ETag }         (useOrganization query)
        │  org.id + current name/address prefill the form; ETag is retained
        ▼
edit name / address ──▶ PATCH /v1/organizations/{org.id}   If-Match: <ETag>
        ├─ 200 ▶ cache replaced with fresh record + new ETag; "saved" status
        ├─ 409 ▶ "someone else changed this — reload" alert + reload button
        ├─ 422 ▶ field errors mapped back onto the inputs; save blocked
        └─ network/other ▶ retryable form-level error
```

- **Why read via `/organizations/me`, write via `/organizations/{orgId}`** — the read resolves
  the org id from the caller's active membership server-side (never chosen client-side), so the
  UI cannot target another org; the PATCH path segment is that same resolved id (FR-TEN-2).
- **ETag / `If-Match`** — the `ETag` from the GET is echoed as `If-Match` on the PATCH; a stale
  value (concurrent edit) is a `409`, surfaced as a clear reload prompt rather than silently
  overwriting. On success the query cache is replaced with the returned record **and its new
  `ETag`**, so an immediate follow-up edit uses the current version — no stale write, no manual
  refetch.
- **Validation** — client-side checks (name required, length limits) mirror the server's
  `OrganizationUpdate` rules for fast feedback and **block the save**; the server remains
  authoritative and a `422` maps its field errors back onto the offending inputs.
- **History** — the edit's entity-history row (actor + timestamp) is written **server-side** in
  the same transaction as the domain write ([#289](https://github.com/TiagoJVO/beekeepingit/issues/289),
  FR-HIS-1); the admin app relies on it and does not re-implement history.

The API client (`src/api/client.ts`) gained `getWithETag` and `patch` (with `If-Match`) for this
flow, plus `conflict` (409) and `validation` (422) `ApiError` kinds; the 422 problem body
(RFC 9457 `errors[]`) is parsed so field errors can be localized. Data-fetching + mutation live
in the `useOrganization` hook; pure form validation lives in `src/components/organizationForm.ts`
(unit-tested independently of the widget).

## 5b. Member management (view/invite/remove) — #74

The second administrative screen (`src/components/MemberManagement.tsx`, rendered below the org
screen in the `AppShell`) lets an admin **view the org's members, invite a new member by email
with a chosen role, and remove a member** (NFR-ROL-2, FR-ONB-3, FR-TEN-2, D-3). Like the org
screen it is scoped to the caller's **own** org — the org id comes from `GET /organizations/me`
(resolved server-side), never chosen client-side — and the server re-enforces admin-only +
org-scope (auth.md §5.3) regardless of the client.

```text
GET /v1/organizations/{orgId}/members?limit=&cursor=  ──▶ { data[], page{ next_cursor } }
        │  rows accumulate via useInfiniteQuery; "load more" appears while next_cursor ≠ null
        ▼
invite:  POST /v1/organizations/{orgId}/invitations  { email, role }
        ├─ 201 ▶ "invitation sent" status; roster query invalidated
        ├─ 422 ▶ email field error (bad address); invite blocked
        └─ 409 ▶ "already invited / already a member" form error
remove:  confirm dialog ─▶ DELETE /v1/organizations/{orgId}/members/{userId}
        ├─ 204 ▶ dialog closes; roster query invalidated (soft-remove server-side)
        ├─ 409 ▶ "can't remove the last admin" — dialog stays open (last-admin guard, D-3)
        └─ 404 ▶ "no longer a member" (ADR-0002 — a non-member is 404, never 403)
```

- **Roster + pagination** — `useMembers` fetches the roster with `useInfiniteQuery`, keyed off
  the server's opaque `page.next_cursor` (ADR-0003 keyset pagination); pages accumulate behind a
  "load more" affordance. The `Member` shape is `user_id`/`role`/`status` only — display names
  live behind the separate least-privilege `.../members/names` roster, not consumed here. The
  **role control (#75) builds on this same roster** — its per-member role picker slots into the
  table's actions column (§5c).
- **Invite with a role at invite time** — the invitee's role is chosen from the fixed
  `admin`/`user` model (`InvitationCreate.role`, auth.md §5.3, NFR-ROL-1) via a labelled
  `<select>`, defaulting to least-privilege `user`. Client-side email validation is a fast-feedback
  gate only (`src/components/inviteForm.ts`, unit-tested); the server re-validates (`format: email`)
  and a `422` maps back onto the field.
- **Remove behind a confirmation** — the destructive remove is gated by an accessible
  `role="alertdialog"` (focus moved in on open, `Escape`/Cancel to dismiss, focus restored to the
  triggering row control). The **last-admin guard is server-enforced** (a `409`, D-3) and surfaced
  as a clear message with the dialog kept open — it is deliberately **not** reimplemented
  client-side as the source of truth.
- **History** — invitation and removal entity-history rows are written **server-side** (FR-HIS-1,
  #290); the admin app relies on that and does not re-implement history.

The API client gained `post` (create → JSON body) and `del` (`204 No Content`) for this flow; the
existing `conflict`/`validation`/`not-found`/`network` `ApiError` kinds carry the 409/422/404 cases.
Data-fetching + the invite/remove mutations live in the `useMembers` hook; the typed member/
invitation calls live in `src/api/members.ts` (unit-tested independently).

## 5c. Roles & permissions management (assign/change + inspect) — #75

Roles management (NFR-ROL-1, auth.md §5.3) is **membership-role management** — the fixed,
org-scoped `admin`/`user` model, not IdP realm roles (auth.md §3.3). It adds two things to the
member screen, both behind the same `AdminGuard` and both server-authoritative:

```text
assign/change: roster actions ─▶ per-member role <select> (active members only)
        │  picking a different role opens a confirm dialog (no eager PATCH)
        ▼
        confirm ─▶ PATCH /v1/organizations/{orgId}/members/{userId}  { role }
        ├─ 200 ▶ "member is now <role>" status; roster query invalidated → reflects new role
        ├─ 409 ▶ "can't demote the last admin" — dialog stays open (last-admin guard, D-3)
        ├─ 404 ▶ "no longer a member" (ADR-0002 — a non-member is 404, never 403)
        └─ 403 ▶ "no permission to change roles" (server re-enforces admin-only)
inspect: collapsible "What can each role do?" panel — the §5.3 capability matrix
```

- **Assign/change from the roster** — each **active** member's actions cell carries a labelled
  role `<select>` (`admin`/`user`); an invited/removed member has none (the change endpoint targets
  active members). The select is controlled by the member's current role, so picking a different
  value doesn't mutate eagerly — it opens an accessible `role="alertdialog"` confirmation ("change
  X from _Member_ to _Admin_?"), mirroring the remove dialog (focus moved in, `Escape`/Cancel to
  dismiss, focus restored, focus-trapped). On confirm the change goes via `changeMemberRole`
  (`PATCH .../members/{userId}` with the `MemberRoleUpdate` body — no `If-Match`; the endpoint has
  no optimistic-concurrency precondition). **The new role is enforced server-side on the target's
  next authorized request** (auth.md §5.3) and recorded in entity history with the acting admin +
  timestamp (FR-HIS-1, #290) — the UI just issues the change, announces success via a `role="status"`
  live region, and lets the invalidated roster re-read the new role.
- **Last-admin guard** — demoting the org's only admin is refused server-side with a `409` (D-3);
  surfaced as a clear message with the dialog kept open, **not** reimplemented client-side.
- **Inspect what each role can do** — `src/components/RoleCapabilities.tsx` renders the fixed §5.3
  capability matrix as a real data table (a row header per capability, a column per role, ✓/—
  marks paired with visually-hidden "Allowed"/"Not allowed" text) inside a collapsible
  `<details>`. It is a **faithful mirror of auth.md §5.3** — it documents, it does not decide, and
  the deferred quotas/rate-limit row (D-4) is intentionally omitted as not-yet-a-capability.

The role-change mutation lives in `useMembers` (`changeRoleMutation`, invalidating the roster on
success); the typed `changeMemberRole` call lives in `src/api/members.ts` (unit-tested). No new
`ApiError` kinds were needed — `conflict`/`not-found`/`forbidden`/`network` already cover the cases.
Server-side enforcement of the change (and the last-admin guard + history) is owned and tested by
#290 (Go), not re-tested here.

## 6. i18n & accessibility

All user-facing strings are externalized in `src/i18n/locales/{en,pt}.json` (NFR-I18N);
react-i18next auto-detects the language with English fallback. Screens use semantic
landmarks/roles (`main`, `role="alert"`, `role="status"`), labelled controls, gloves-friendly
44px/56px tap targets (D-18), visible focus outlines, and light/dark theming. `jest-axe`
asserts the admin shell has no automatically-detectable a11y violations.

## 7. Configuration & secrets

All config is `VITE_*` env vars (`admin/.env.example`); a missing required var renders a clear
**configuration-error** screen instead of a blank page. **No secrets are committed** — the
public-client + PKCE design means there is no client secret to hold.

## 8. Build & CI

`npm run build` (`tsc` typecheck + Vite) emits a static `dist/` bundle, served by nginx via
`admin/Dockerfile` with security headers (`admin/nginx.conf`; CSP shipped Report-Only for the
first release, same rollout as the client — #89). CI wiring:

- **Lint + test** — `ci.yml` → `task ci` → `taskfiles/web.yml` auto-discovers `admin/` and
  runs `npm run lint` / `npm test`.
- **Build + lint + test + image** — `build-publish.yml` detects `admin/` (it has a
  `Dockerfile`) and runs `npm ci && npm run lint && npm test && npm run build`, then builds
  and Trivy-scans the image — the same shape as the Go services and the Flutter client.
- **Dependency updates** — Dependabot `npm` ecosystem on `/admin`
  (`.github/dependabot.yml`).
