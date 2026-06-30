---
name: backlog-management
description: >-
  How BeekeepingIT's backlog is structured in GitHub (Milestones → Epics → Stories/Tasks via native
  sub-issues) and the conventions for creating or editing any issue. Use when planning, creating, or
  grooming backlog items — epics, stories, tasks, sub-issues, milestones — or when editing issue
  titles, bodies, or labels. Captures the non-obvious rules we settled on: a title/body must never
  duplicate what GitHub already tracks natively (parent epic = the sub-issue link, type = the type/*
  label, milestone = the Milestone field, dependencies = blocked-by relationships); epics track
  children only through the Sub-issues panel,
  never a hand-maintained Stories checklist; but FR-*/NFR-*/D-*/Q-* traceability IDs DO stay in the
  body. The backlog lives in Issues + Projects — the planning/ folder is retired.
---

# Managing the backlog (Milestones, Epics, Tasks, Sub-issues)

The plan/backlog lives in **GitHub Issues + Projects** (the old `planning/` folder was migrated and
**retired** — see [CLAUDE.md](../../../CLAUDE.md)). `requirements/` holds *intent*
(`FR-*`/`NFR-*`/`D-*`/`Q-*`); this skill is about how that intent is tracked as **work**. Always
map an item to its requirement IDs first — see the **requirements-folder** skill and the
`mandatory-workflow` rule.

## The hierarchy & the native mechanisms

```
Milestone (M0…M5)            time-boxed delivery target
└─ Epic                      issue, label type/epic, titled "EPIC-XX — Name"
   └─ Story / Task           issue, linked as a native SUB-ISSUE of the epic
      └─ Sub-task            sub-issue of a story (only when a story needs breaking down)
```

Each mechanism has **one** job — never re-implement one in prose:

| Mechanism | What it is | What it's for |
|---|---|---|
| **Milestone** | flat, date-bound bucket; progress = closed ÷ total | "is M0 on track?" |
| **Sub-issues** | native parent/child link with its own progress bar | the epic→story hierarchy — **source of truth** |
| **Labels** | `type/ area/ priority/ size/ status/` | classification & filtering |
| **Project (v2)** | table/board; *Group by → Parent issue* | the working view; expand an epic to its tasks |
| **Dependencies** | native *blocked-by* / *blocking* links (Relationships panel) | sequencing — what must ship before what |

The Milestone view is **flat** — it can't nest or show "only epics". Hierarchy comes from
sub-issues (on the epic page) and the Project, not the milestone.

## Golden rule: don't duplicate a native field in the title or body

If GitHub tracks it as a field, relationship, or label, do **not** restate it in text. What we
removed across the backlog, and must not reintroduce:

- ❌ `**Epic:** #103` or prose `Part of **EPIC-08** (#9)` → the **sub-issue parent link** shows it.
- ❌ `**Type:** Task` → the **`type/*` label** shows it.
- ❌ `**Milestone:** M0`, or a `(M0)` suffix in the title → the **Milestone field** shows it.
- ❌ `EPIC-XX:` prefix in a child title → parent is the sub-issue link.
- ❌ `**Depends on:** #N` in the body → use the native **blocked-by dependency** (Relationships panel).
- ❌ `<sub>Generated from planning/…</sub>` footers → the `planning/` folder is retired.

What **stays** in the body (GitHub has no native field for these):

- ✅ `**Requirements:** FR-…, NFR-…` and `**Decisions:** D-…` — traceability IDs, cited repo-wide.
- ✅ `**Phase:**` / `**Spans:**` — rollout phase (`D-10`) and milestone-span notes on epics.

## Body shape

**Story / Task / Feature / Chore**
```
<optional one-line intent>
**Requirements:** FR-…, NFR-…
**Decisions:** D-…            (only if it relies on one)

### Acceptance criteria
- [ ] …

> **Notes:** …               (optional)
```
Dependencies are not a body line — set them as native **blocked-by** relationships (see recipes).

**Epic** — intro paragraph, then any `**Phase:**` / `**Spans:**`, `**Requirements:**`, and
`### Definition of done`. **No Stories list**: children live in the
Sub-issues panel, which auto-tracks "X of N done". A manual checklist only drifts and forces
hand-updates on every completion.

## Titles
Plain, imperative, specific — no `EPIC-XX:` prefix, no `(Mx)` tag, no `[Type]` prefix. The lone
exception is epics themselves: `EPIC-XX — Short Name` (em dash, not a colon).

## Labels (`.github/labels.yml`)
- **type/** (exactly one): `epic story task feature bug chore spike research docs`
- **area/**: `activities apiaries journeys ai todos offline-sync auth-identity org-tenancy rbac
  history-audit admin-app import-export maps-geo i18n-a11y infra observability security`
- **priority/**: `critical high medium low` · **size/**: `xs s m l xl` ·
  **status/**: `needs-triage blocked needs-info ready`

## Milestones — what to assign
The bar is just closed ÷ total of assigned issues. **Recommended:** assign **leaf issues**
(stories/tasks) to a milestone for an honest burndown, and read epic progress from the Sub-issues
bar + the Project grouped by epic. Pick one assignment policy and apply it consistently. An epic
stays in its **first** milestone; per-phase work is carried by the **sub-issues' own** milestones —
that is exactly what `**Spans:**` documents.

## Tooling recipes (`gh` has no first-class sub-issue commands)
`gh` is authenticated here; the REST API drives sub-issues. The repo is public, so reads also work
unauthenticated.

```bash
# list an issue's sub-issues
gh api repos/OWNER/REPO/issues/<n>/sub_issues

# wire a child under a parent — needs the child's REST *id*, not its number
id=$(gh api repos/OWNER/REPO/issues/<child#> --jq .id)
gh api --method POST repos/OWNER/REPO/issues/<parent#>/sub_issues -F sub_issue_id=$id

# dependencies: "<n> depends on <dep>" == <n> is blocked_by <dep> (also needs the dep's *id*)
id=$(gh api repos/OWNER/REPO/issues/<dep#> --jq .id)
gh api --method POST   repos/OWNER/REPO/issues/<n>/dependencies/blocked_by -F issue_id=$id
gh api                 repos/OWNER/REPO/issues/<n>/dependencies/blocked_by          # list
gh api --method DELETE repos/OWNER/REPO/issues/<n>/dependencies/blocked_by/$id      # remove

# edit a title/body safely — write the body to a file to avoid shell-quoting pain
gh issue edit <n> --title "…" --body-file new-body.md
```

Definition of Done, tenancy, i18n, security and the rest of the finishing bar are governed by the
`definition-of-done` rule — this skill only covers backlog **structure**.
