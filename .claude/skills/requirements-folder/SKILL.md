---
name: requirements-folder
description: >-
  How to work with the requirements/ folder in BeekeepingIT — the source of truth for intent.
  Use when planning a task (to find the related FR-*/NFR-* requirements, D-* decisions, and open
  Q-* questions it touches) and whenever adding or editing anything under requirements/ (decisions,
  functional/non-functional requirements, open questions, context, tech-stack). Captures the
  non-obvious conventions: requirements/ is intent while docs/ is as-built; IDs are stable and
  cited repo-wide; decisions change only with user confirmation; and a resolved open question is
  REMOVED, its answer moved to a D-*/requirement/doc that cites the Q-* ID.
---

# Working with `requirements/`

The source of truth for **intent** — what we want and why. (`docs/` is the *as-built* record;
don't conflate them.) **When planning a task, read it for the topics the task touches** — the
`FR-*/NFR-*` it implements, the `D-*` decisions it relies on or touches, and any open `Q-*` it
must clarify first — and identify those before writing code.

## Non-obvious conventions

- **IDs are load-bearing.** `D-*` / `FR-*` / `NFR-*` / `Q-*` / `C-*` are cited from other
  requirements, `docs/`, branches, commits and PRs. Don't renumber or rename them; **add** new
  IDs, never reuse retired ones.
- **Decisions are the default, but revisitable — never silently.** If contradicting a `D-*` or a
  requirement genuinely makes sense, **stop, propose it to the user, and only on confirmation
  update** the `D-*`/requirement (noting what changed). A blocking unresolved `Q-*` is surfaced,
  not assumed away. Editing `requirements/` changes intent, so it needs user sign-off.
- **A resolved open question is removed, not archived.** `open-questions.md` holds only OPEN (or
  explicitly deferred) questions. When one is answered, delete its entry and write the answer in
  its place of record — a `D-*` (with `**Supersedes:** Q-XXX`), an `FR-*/NFR-*`, or `docs/` —
  which then carries the traceability. Partially answered → **narrow** the entry to what's left;
  deferred ≠ resolved (keep it, mark the trigger to revisit).
- **`frs.txt` / `nfrs.txt` are the raw original brain-dump**; the `*-requirements.md` files are
  the curated, ID'd version and are authoritative. Don't cite the `.txt` files.
