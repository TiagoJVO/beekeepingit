# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## Apiary CRUD PostGIS bug (`fix/apiaries-geography-search-path`, follows #31) — before-merge note

`services/apiaries/store/migrations/00003_add_apiary_location.sql` (#31, merged) referenced the
bare `geography` type — resolvable only when `public` is on the connection's search path. Each
service connects with `search_path` restricted to its own schema (`DB_SEARCH_PATH`), which
excludes `public` (where `CREATE EXTENSION postgis` installs its types) — so the apiaries
service crash-loops on startup in any real deployment. Confirmed live against a k3d cluster;
testcontainers tests pass because their default search path includes `public`, silently masking
this. Fixed by schema-qualifying every `geography` reference as `public.geography`.

**Separately flagged, not fixed here:** the "k3d cluster + helm test" CI workflow only verifies
Postgres/PostGIS and Authentik readiness — it never checks whether the application pods
(apiaries/identity/organizations/sync) actually reach `Ready`. That gap is how this shipped
undetected. Worth a dedicated follow-up (promote to an Issue) to add an application-pod
readiness check to that workflow; out of scope for this hotfix.

## Keycloak → Authentik migration — post-merge follow-ups

The migration (contract + ADR-0016 + D-7; WS-A infra, WS-B backend, WS-C client, WS-D docs) shipped in
**#191** (merged). Remaining coordinator follow-up (to promote to a GitHub Issue, then prune here):

- **Backlog grooming** — rename **#72** (Keycloak → OIDC auth), retarget **#98** / EPIC-14 **#15**
  auth-hardening scope to Authentik (flows/blueprints/secrets), reconcile other open Keycloak-mentioning
  issues.

(Live browser-login re-validation is already tracked as **#193**, opened separately — no longer
duplicated here.)

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

- **Confirmed & added** — `FR-AP-8` (apiary notes, #196) and `FR-UX-2` (app-shell IA, folded into the
  field-first `FR-UX` track, #197) are now in `requirements/functional-requirements.md`.
- **Feed the scope pass** — the prototype answers `Q-DIST`/`Q-SEARCH`/`Q-MAP`/`Q-JOUR`/`Q-TODO`/`Q-NOTIF`
  (see `docs/design/prototype.md`); use those when settling each `Q-*` (answer → `D-*`/`FR-*`, delete the `Q-*`).
