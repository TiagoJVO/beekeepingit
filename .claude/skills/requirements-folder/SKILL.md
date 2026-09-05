---
name: requirements-folder
description: >-
  The non-obvious conventions of BeekeepingIT's requirements/ folder — the source of truth for
  intent. Use when adding or editing anything under requirements/, or when an open question gets
  answered. Covers what the mandatory-workflow rule doesn't: IDs are stable and cited repo-wide, a
  resolved Q-* is REMOVED (its answer moves to a D-*/requirement/doc that cites the Q-* ID), and
  which files in the folder are authoritative.
---

# Editing `requirements/`

`requirements/` is **intent**; `docs/` is the **as-built** record — don't conflate them. When to
read it, and the "decisions change only with user confirmation" rule, live in the
`mandatory-workflow` rule; this skill is the folder's own conventions.

- **Layout.** `decisions.md` (`D-*`), `functional-requirements.md` / `non-functional-requirements.md`
  (`FR-*`/`NFR-*`), `open-questions.md` (`Q-*` — only what is still OPEN or deferred), `context.md`
  (`C-*`), `tech-stack.md`. The `.txt` files are the raw original brain-dump; the `.md` files are
  the curated, ID'd version and the only ones to cite.
- **IDs are load-bearing.** They are cited from other requirements, `docs/`, ADRs, branches,
  commits, issues and PRs. Never renumber or rename one; **add** new IDs, never reuse a retired one.
- **A resolved open question is removed, not archived.** Delete its entry from `open-questions.md`
  and write the answer in its place of record — a `D-*` (with `**Supersedes:** Q-XXX`), an
  `FR-*`/`NFR-*`, or `docs/` — which then carries the traceability. Partially answered → **narrow**
  the entry to what's left. Deferred ≠ resolved: keep it, and record the trigger to revisit.
