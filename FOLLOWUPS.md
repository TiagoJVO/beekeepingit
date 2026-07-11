# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## Identity/org history (`feat/EPIC-07-identity-org-history`, #165, FR-HIS-1) — before-merge note

`identity.audit_log` and `organizations.audit_log` (+ wiring into profile create/update, org
creation, invite/accept/revoke) ship in this branch — all in-transaction with their domain
writes, reusing `services/shared/history.ComputeChange` per #59's pattern.

**Scoped out, not built:** #165's AC says "removing an org membership... writes a history
record", but there is **no membership-removal code path anywhere in the codebase** to wire
history into — `services/organizations/api/memberships.go` only has the internal
active-membership resolve endpoint; there is no handler, route, or SQL query for removal.
`organizations.memberships.status` already reserves the `'removed'` value
(`store/migrations/00001_create_organizations.sql`) and `ListMembers` already excludes it, but
both are explicitly noted as "future-proofed, not built" — consistent with the organizations
README's existing "Member removal... are not built — D-3 and FR-ONB-3 both flag these as
still-open detail." Building a removal endpoint was out of this issue's scope (it owns wiring
history into existing seams, not implementing new domain functionality). When member removal
is built (tracked under D-3/FR-ONB-3, no dedicated issue number yet — check the EPIC-01 #2
sub-issues or file one), it should write its own `organizations.audit_log` row
(`entity_type = 'membership'`, `change_type = 'update'`, status `active` → `removed`) using the
same `writeAuditLog` helper in `services/organizations/api/audit.go` this branch adds.

---

## Offline sync + history (`feat/EPIC-07-offline-sync-history`, #61, FR-HIS-1/FR-OF-1) — before-merge notes

Builds the gaps #59 (merged, #202) left open: `apiaries.audit_log` + `apiaries.sync_conflict_log`
added to the PowerSync Sync Rules org bucket (`infra/helm/beekeepingit/charts/powersync/values.yaml`,
offline-viewable history/conflict rows), a combined `ListEntityTimeline` sqlc query (audit_log UNION
ALL sync_conflict_log, loser tagged `history.EventSuperseded`), and an end-to-end conflict-scenario
test (`TestApiariesSlice_History_ConflictSurfacesInCombinedTimeline`). Pending:

- **Rebase against #31** (apiary CRUD REST handlers, parallel PR touching the same
  `services/apiaries/api/apiaries.go` + migrations) once both land — expected per the coordinator,
  not a defect.
- **"Recent window" nuance not cleanly bounded** — history.md §6 asks for a "recent window" of
  `audit_log`/`sync_conflict_log` to replicate down, but PowerSync Sync Rules bucket `data` queries
  don't support LIMIT/rolling time-window semantics (they define a continuously-replicated row set).
  v1 replicates the full per-org history down (same flat-`SELECT *` style as the existing `apiaries`
  bucket entry). Revisit if/when per-org audit volume grows enough to matter (§3's "Trade-off
  (accepted)" already anticipates this is bounded by real change volume) — a genuine bound would need
  either an engine-level feature PowerSync doesn't have today, or a server-side pre-aggregation/
  projection step, which is more than this issue's scope.
- **Live end-to-end replication of `audit_log`/`sync_conflict_log` down to a device** was not
  verified against a running PowerSync instance (per the coordinator's explicit call: static Sync
  Rules YAML correctness via `helm lint`/`helm template` + a Go-level test of the underlying query is
  the verified scope; a live-cluster check was out of bounds for this agent). Worth a quick live check
  next time the umbrella chart is deployed to k3d.

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
