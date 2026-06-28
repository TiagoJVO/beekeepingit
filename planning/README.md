# Planning

Source-of-truth Markdown for work breakdown. These files are authored here and then
used to **generate GitHub Issues and a GitHub Project board**.

> Status: **populated.** See [roadmap.md](roadmap.md) for milestones, ordering, and
> the dependency graph; [epics/](epics/) holds the per-epic stories.

## Structure

```
planning/
├── roadmap.md        # Master: milestones (M0–M5), ordering, dependency graph, deferred
├── epics/            # One file per epic (EPIC-00..15, 90, 91) → GitHub Issues
└── scripts/          # gh-based generators (create issues, project, labels) — later
```

## Conventions (so MD → GitHub is scriptable)

Each **epic** file lists its **features/stories**, each with YAML-ish frontmatter a
script can parse into `gh issue create`:

```markdown
# EPIC-02 — Apiaries
- **Milestone:** M1
- **Labels:** type/epic, area/apiaries
- **Requirements:** FR-AP-1..7
- **Depends on:** EPIC-01, EPIC-06

## Stories
### [Feature] Apiary CRUD (FR-AP-1)
- **Labels:** type/feature, area/apiaries, priority/critical
- **Requirements:** FR-AP-1
- **Milestone:** M1
- **Acceptance criteria:**
  - [ ] Create/read/update/delete an apiary
  - [ ] Change recorded in history (FR-HIS-1)
```

> Note: story headers currently appear as both `### [Feature] …` and `### Feature …`
> across files — the generator should accept either (a small normalization pass is a
> nice-to-have).

Mapping:

- **Epic** → a tracking Issue labelled `type/epic` (or a Project milestone).
- **Feature/Story/Task** → a GitHub Issue with the listed labels, milestone, and
  body (acceptance criteria + requirement refs).
- All generated issues are added to the **GitHub Project** board.
- Labels come from [../.github/labels.yml](../.github/labels.yml).

## Generation (later)

A script in `scripts/` (using `gh`) will: sync labels → create/update milestones
(M0–M5) → create issues from the epic files (idempotent via a title/marker) → add them
to the Project. **The epics now exist** — this script is the next planning deliverable.
