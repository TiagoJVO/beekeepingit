# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

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
