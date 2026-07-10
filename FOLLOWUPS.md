# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## Keycloak → Authentik migration — post-merge follow-ups

The migration (contract + ADR-0016 + D-7; WS-A infra, WS-B backend, WS-C client, WS-D docs) ships in
**#191** — CI-green, including a live Authentik deploy passing the helm-e2e readiness check. Remaining
coordinator follow-ups (to promote to GitHub Issues, then prune here):

- **Live browser-login re-validation** — stand the full stack up on k3d and drive a real PKCE
  login/logout against Authentik through the dual-host gateway (`app.` / `auth.`). CI proved deploy
  health and the OIDC spike proved token → `go-oidc` validation; the full browser round-trip is the
  last check. WS-A also flagged `offline_access` consent-stage + blueprint `password`/`upn` to confirm
  live on the pinned version.
- **Backlog grooming** — rename **#72** (Keycloak → OIDC auth), retarget **#98** / EPIC-14 **#15**
  auth-hardening scope to Authentik (flows/blueprints/secrets), reconcile other open Keycloak-mentioning
  issues.
