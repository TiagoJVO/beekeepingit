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

## App shell IA (`feat/EPIC-11-app-shell-ia`, #197, FR-UX-2) — before-merge notes

The 5-tab bottom nav + header + contextual FAB + offline banner ship in this branch. Two
pieces are **stubbed on purpose** and already tracked by an existing issue — no new issue
needed, just flagging for the next agent who picks up **#58**:

- **Sync-status pill** (`client/lib/shell/sync_status.dart`'s `syncStatusProvider`) is a fixed
  "online, nothing pending" `Provider`, not wired to PowerSync's real `statusStream`/upload-queue
  depth. The pill's UI (color/label/tap→`/account`) is real; only the data source is a stub.
- **Offline banner** reads the same stub, so it never renders in practice yet (hidden whenever
  `SyncConnectivity.online`). Placement/shell wiring is done; #58 replaces the provider's body.

Also relocated (not scope creep — the apiaries list lost its own `AppBar` to the shell's header,
so these needed a new home): `manage-members` (#172) and `logout` moved from the apiaries
app-bar actions to the account screen (`account-manage-members-button`,
`account-logout-button`), matching the prototype's "Conta" screen.

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

- **Confirmed & added** — `FR-AP-8` (apiary notes, #196) and `FR-UX-2` (app-shell IA, folded into the
  field-first `FR-UX` track, #197) are now in `requirements/functional-requirements.md`.
- **Feed the scope pass** — the prototype answers `Q-DIST`/`Q-SEARCH`/`Q-MAP`/`Q-JOUR`/`Q-TODO`/`Q-NOTIF`
  (see `docs/design/prototype.md`); use those when settling each `Q-*` (answer → `D-*`/`FR-*`, delete the `Q-*`).
