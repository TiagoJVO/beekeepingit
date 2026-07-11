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

## Milestone/stream regroom (D-14) — follow-ups

Flat **M0–M5** re-sliced into a per-feature ladder + cross-cutting streams; the GitHub
Issues/Milestones/dependency edits are already applied (this PR records the model in **D-14**).
Pending (promote to Issues, then prune here):

- **Scope gates** — settle before sizing a feature's stories: `Q-MAP`/`Q-DIST`/`Q-SEARCH` → M2
  (first), `Q-JOUR` → M4, `Q-TODO` → M5, `Q-IMP` → M6, `Q-AICLOUD` → M8, `Q-NOTIF` → M9. Resolve via
  the `requirements-folder` skill (answer → `D-*`/`FR-*`, then delete the `Q-*`).
- **`#60`** ("history view per apiary/activity/journey", now M3) may want splitting per entity during grooming.
- **Provisional stream-story placements** — `#56–59`/`#61–62`/`#165` → M2, `#90`/`#92` → M6 by
  "first need"; revisit if a thinner M2 is wanted.
- **Project board** — re-check any saved views that filtered the now-deleted `M2–M5`.

Rollback snapshot if needed: `scratchpad/backlog-backup-2026-07-11/` (+ `RESTORE.md`).

## Melargil prototype import — follow-ups

The product's interactive prototype ("Melargil") is now in-repo at `docs/design/melargil-prototype/` +
[`docs/design/prototype.md`](docs/design/prototype.md) as the **UI/UX guideline** (not a spec). It validates the
M0–M11 backlog and answers 6 open `Q-*`. This PR adds: the prototype in-repo, epic `**Prototype:**` links
(#2/#3/#4/#5/#6/#9/#13), 2 net-new stories, and spec-note refinements (#38/#49/#58/#65/#82). Pending:

- **Confirm the two proposed `FR-*`** before they land in `requirements/`: `FR-AP-8` (apiary notes, #196) and
  `FR-UX-1` (app-shell IA — 5-tab nav + contextual FAB + header, #197). The issues reference them provisionally.
- **Feed the scope pass** — the prototype answers `Q-DIST`/`Q-SEARCH`/`Q-MAP`/`Q-JOUR`/`Q-TODO`/`Q-NOTIF`
  (see `docs/design/prototype.md`); use those when settling each `Q-*` (answer → `D-*`/`FR-*`, delete the `Q-*`).
