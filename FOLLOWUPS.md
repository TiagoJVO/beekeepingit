# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## Branch `feat/replace-keycloak-with-authentik` — Keycloak → Authentik migration (coordinator-run)

Full E2E replacement of Keycloak with **Authentik** behind a provider-agnostic OIDC boundary.
Contract: [`docs/architecture/oidc-integration.md`](docs/architecture/oidc-integration.md) · decision:
[ADR-0016](docs/adr/0016-replace-keycloak-with-authentik.md) · [D-7](requirements/decisions.md#d-7).
Phase 0 (contract + ADR + D-7 + tech-stack) is **committed** (`0df098e`). Workstreams land as PRs
into this integration branch; it merges to `main` once coherent and green.

- **WS-A infra** (`feat/authentik-ws-a` → PR): Authentik Flux HelmRelease + wrapper subchart +
  blueprint + `auth.beekeepingit.local` gateway host + dev scripts + CI. **Status:** agent in progress.
- **WS-B backend** (`feat/authentik-ws-b` → PR): `keycloak_sub`→`oidc_sub` migration + sqlc regen,
  devseed, comment/config sweep, tests. **Status:** agent in progress.
- **WS-C client** (`feat/authentik-ws-c` → PR): discovery-driven `openid_client`, front-channel
  logout, account URL, l10n, unit + e2e. **Status:** agent in progress.
- **WS-D docs** (pending): rewrite `auth.md` + architecture docs + root README/CLAUDE sweep — spawned
  after A/B/C so it documents as-built. **Status:** not started.
- **WS-E backlog** (coordinator): rename **#72** (Keycloak→OIDC), sweep **#98**/EPIC-14 **#15** auth
  scope to Authentik flows/blueprints, create the migration epic. **Status:** recon done, edits pending.
- **Live-cluster OIDC re-validation** (coordinator, via cluster semaphore): on the pinned Authentik
  version, confirm blueprint applies clean + full PKCE login/logout end-to-end (WS-A flags the exact
  items in its PR: `offline_access` consent stage, blueprint `password`/`upn`). **Status:** pending.
- **Phase 2 gate:** `grep -ri keycloak` == 0 across the repo before the integration→`main` PR.
