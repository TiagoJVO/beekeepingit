# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## Accessibility & field-first UX (`feat/EPIC-a11y-field-ux-79-80`, #79/#80) — post-merge note

#79/#80 landed the automated half of the checklist (`docs/design/accessibility-field-ux-checklist.md`,
D-18): tap-target sweep tests, semantics-label tests, a keyboard focus-order test, and a WCAG 2.2 AA
contrast regression test against the real theme values (`client/test/theming/app_theme_contrast_test.dart`).

**Not done — needs a human, tracked honestly in the checklist's pass log (not claimed as done):**

- **Screen-reader pass** (TalkBack/VoiceOver/NVDA) over login, apiaries list/form, account/org/members.
- **Keyboard-only pass** in a real browser (not just simulated Tab-key widget tests).
- **Gloved-use pass** on a physical touchscreen device.

**Action:** whoever picks this up next should run the three passes in
`docs/design/accessibility-field-ux-checklist.md`'s "Manual pass protocol" section, fill in the
pass log with real dates/results, and file any findings as new issues (referencing FR-AX-1/FR-UX-1).
Once done, prune this entry — the checklist's own pass log is the durable record, not this file.

## Offline UX: sync status/queued changes/retry (`feat/EPIC-06-offline-sync-ux`, #58) — before-merge note

#58 builds the sync-status UI (real connectivity + pending count via `PowerSyncDatabase
.statusStream`/`getUploadQueueStats`, a non-blocking "superseded" toast, manual "sync now",
`client/lib/shell/sync_status.dart` + `client/lib/core/sync/`) against what already exists.

**Gap found, not built here (by design — flagging per the issue's own instructions):** the
**connection-quality gate** (FR-OF-3, [sync.md](docs/architecture/sync.md) §7.1 — "connect/flush
only when a quality probe passes, ~usable 3G, with backoff") does not exist yet anywhere in the
client (no gateway-reachable health/probe endpoint, no Network Information API / `connectivity_plus`
usage). sync.md §10 itself hands this mechanism to **"EPIC-06 (#55/#58)"**, and re-reading **#55**
("Client local store + sync integration") confirms **#55, not #58, owns building the actual gate**
(its AC explicitly includes "connect/flush only when a quality probe passes... exponential backoff
and a manual sync now override — mechanism in sync.md §7.1") — #55 is still open, so the gate is
simply not built yet anywhere. #58 does not attempt to build a parallel gate; it only adds the
manual "sync now" override (already in scope per #58's own AC) and will surface the gate's
"waiting for better signal" state once #55 lands (no rework expected — `SyncStatus` has room to
grow additively). **Action:** none needed here beyond this note; #55 already tracks the real work.

## Keycloak → Authentik migration — post-merge follow-ups

The migration (contract + ADR-0016 + D-7; WS-A infra, WS-B backend, WS-C client, WS-D docs) shipped in
**#191** (merged). Remaining coordinator follow-up (to promote to a GitHub Issue, then prune here):

- **Backlog grooming** — rename **#72** (Keycloak → OIDC auth), retarget **#98** / EPIC-14 **#15**
  auth-hardening scope to Authentik (flows/blueprints/secrets), reconcile other open Keycloak-mentioning
  issues.

(Live browser-login re-validation shipped and closed as **#193**.)

## Milestone/stream regroom (D-14) — follow-ups

Flat **M0–M5** re-sliced into a per-feature ladder + cross-cutting streams; the GitHub
Issues/Milestones/dependency edits are already applied (this PR records the model in **D-14**).
Pending (promote to Issues, then prune here):

- **Scope gates** — settle before sizing a feature's stories: `Q-MAP` → M2 (narrowed to
  offline-tile caching/provider; `Q-DIST`/`Q-SEARCH` already resolved via `D-*`, removed),
  `Q-JOUR` → M4, `Q-TODO` → M5, `Q-IMP` → M6, `Q-AICLOUD` → M8, `Q-NOTIF` → M9. Resolve via
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

- `FR-AP-8` (apiary notes, #196) and `FR-UX-2` (app-shell IA, folded into the field-first
  `FR-UX` track, #197) landed in `requirements/functional-requirements.md` (#199, merged) and are
  now **implemented** (#32/#196, #197) — no longer pending.
- **Feed the scope pass** — the prototype answers `Q-MAP`/`Q-JOUR`/`Q-TODO`/`Q-NOTIF` (see
  `docs/design/prototype.md`); use those when settling each remaining `Q-*` (answer →
  `D-*`/`FR-*`, delete the `Q-*`). `Q-DIST`/`Q-SEARCH` are already resolved and removed.
