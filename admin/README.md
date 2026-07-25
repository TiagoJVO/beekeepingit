# admin

The **web admin app** (`D-5`, `NFR-ROL-2`) — a **React + TypeScript**, **online-only**
(no offline / PWA / service worker) browser app for organization administration: managing
members, roles and invitations (`auth.md` §5.3). Scaffolded by [#72](https://github.com/TiagoJVO/beekeepingit/issues/72)
(M7): OIDC login, the admin-role guard, a typed authenticated API client, and a guarded
landing shell. Its first administrative screen is **organization management** — view/edit the
org's name and address with `If-Match` optimistic concurrency ([#73](https://github.com/TiagoJVO/beekeepingit/issues/73));
further screens (members, roles, invitations) land in follow-up M7 stories.

Architecture as-built: [`docs/architecture/admin-app.md`](../docs/architecture/admin-app.md).
It authenticates against the platform OIDC provider behind the provider-agnostic boundary
([`docs/architecture/oidc-integration.md`](../docs/architecture/oidc-integration.md),
[ADR-0016](../docs/adr/0016-replace-keycloak-with-authentik.md)).

## Stack

| Concern      | Choice                                                           |
| ------------ | ---------------------------------------------------------------- |
| Build tool   | **Vite** (`tech-stack.md` — Admin web app)                       |
| Language     | **TypeScript** (strict) + React 19 (function components + hooks) |
| Auth         | **`react-oidc-context`** (discovery-driven, Auth Code + PKCE)    |
| Server state | **TanStack Query**                                               |
| i18n         | **react-i18next** (EN + PT, strings externalized — `NFR-I18N`)   |
| Tests        | **Vitest** + React Testing Library + jest-axe (a11y)             |
| Lint/format  | ESLint (flat config, typescript-eslint) + Prettier               |

No CRUD-scaffolding framework (Refine / React-Admin) is pulled in yet — the single
hand-built org screen does not justify one (YAGNI); the option stays open per `tech-stack.md`.

## Run it

```sh
npm install
cp .env.example .env.local   # then edit for your environment
npm run dev                  # http://localhost:5174
```

All configuration is via `VITE_*` env vars — see [`.env.example`](.env.example). **No
secrets**: the admin app is a **public** OIDC client using Authorization Code + PKCE (no
client secret to keep — `auth.md` §3.2). Account and password management stay at the IdP
(`D-7`); the app links out to `VITE_ACCOUNT_URL`, it never implements those flows.

## Scripts

```sh
npm run dev        # Vite dev server
npm run build      # tsc typecheck + vite production build → dist/
npm run lint       # eslint + prettier --check
npm run format     # prettier --write + eslint --fix
npm test           # vitest run
npm run test:coverage
```

The repo-wide `task lint` / `task test` / `task build` auto-discover this package via
`taskfiles/web.yml`; CI runs the same gates (`.github/workflows/ci.yml`, and the
build+lint+test+image step in `build-publish.yml`).

## How auth + the admin guard work

1. **Login** — `react-oidc-context` runs Authorization Code + PKCE against the issuer
   (`VITE_OIDC_ISSUER`); every endpoint is read from the issuer's discovery document, so the
   IdP is a swappable detail (`oidc-integration.md` §1).
2. **Role guard** — the `admin`/`user` role is **org-scoped and resolved server-side** — it
   is **not** an OIDC token claim (`auth.md` §3.4). After login the app calls
   `GET /v1/organizations/me` (bearer token attached by the typed API client) and reads the
   caller's `role`. **Only `role === "admin"` reaches the app shell**; a `user` (or any
   non-admin) sees a clear "admin access required" message; a `404` (no membership) sees a
   "join an organization first" message.
3. **Token on every call** — the API client attaches `Authorization: Bearer <access_token>`
   to every request; the server rejects missing/expired tokens with `401` (`NFR-SEC-1`).

The guard's decision logic (`src/auth/access.ts`) is a pure function, unit-tested for every
branch; the wired `AdminGuard` is integration-tested (admin allowed, non-admin denied) with
React Testing Library (`NFR-TST-1`).

## Deferred seams

Quotas & rate-limit management (`NFR-RL-1` / `NFR-ROL-2`) is **deferred out of v1** (`D-4`):
nothing is enforced against users and no quota logic exists. The admin app carries only an
**inert seam** for it (`src/components/QuotasSeam.tsx`) — a disabled "coming later" nav entry
that the real screens slot into when **EPIC-91** is picked up. It ships **hidden**, gated
behind the default-off `VITE_FEATURE_QUOTAS_SEAM` flag (see [`.env.example`](.env.example)).
