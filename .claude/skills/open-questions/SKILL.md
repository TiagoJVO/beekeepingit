---
name: open-questions
description: >-
  How to read, add, and resolve open questions (Q-* items) in
  requirements/open-questions.md for BeekeepingIT. Use this whenever you add a new open
  question, answer/close/resolve one, run into a Q-* while planning, record a decision
  that settles a Q-*, or edit requirements/open-questions.md. Critically: a resolved
  question is REMOVED from the file (never archived in place) and its answer is written
  to its place of record — a D-* decision, an FR-*/NFR-*, or docs/ — with that artifact
  citing the Q-* ID. The file holds only genuinely open or explicitly deferred questions.
---

# Handling open questions (`Q-*`)

`requirements/open-questions.md` is BeekeepingIT's **worklist of unresolved decisions** —
the `FR-*/NFR-*` gaps and conflicts still to settle. Its value comes entirely from being a
*live* list: a reader should open it and see **only what still needs deciding**. The moment
it accumulates resolved entries it stops being a worklist and becomes a confusing archive
where the same fact lives in two places and drifts out of sync.

So the governing rule is simple: **the file holds only open (or explicitly deferred)
questions. When a question is answered, remove it and write the answer where it belongs.**

## The place of record for an answer

A `Q-*` never keeps its own answer long-term. When resolved, the answer lives in the
artifact that owns that kind of fact, and that artifact **cites the `Q-*` ID** so the trail
survives the removal:

| The answer is… | Write it in… | How traceability is kept |
|---|---|---|
| A cross-cutting choice (tech, architecture, scope) | a decision `D-*` in `decisions.md` | the `D-*` adds `**Supersedes:** Q-XXX` (or `**Extends/Refines:**`) |
| A clarified product behavior | the relevant `FR-*` / `NFR-*` | the requirement's wording now covers it; cite the `D-*`/`Q-*` if useful |
| A detail about how something was built | `docs/` (+ an ADR if significant) | the doc / ADR references the `Q-*` / `D-*` |

Git history **plus** that back-reference are the traceability. Do **not** leave a dead
`✅ RESOLVED` stub in `open-questions.md` to "remember" the answer — the decision is the
memory, and it holds the rationale better than a stub ever could.

## Reading open questions (when planning)

Per the mandatory-workflow rule, when you plan a task: scan this file for any `Q-*` whose
**Affects** lists an `FR-*/NFR-*` you're touching. If an unresolved `Q-*` blocks the task,
**surface it to the user** — never silently assume an answer.

## Adding an open question

Place it in the tier that matches its planning impact (Tier 1 reshapes the whole plan →
Tier 4 is a small clarification) and follow the house format:

```
### Q-XXX — <short title>
- **Affects:** the FR-*/NFR-* (and C-* context) it touches.
- **Gap / Conflict:** what is undefined or contradictory, and why it matters.
- **Decisions needed:** the specific sub-choices to make.
- **Recommended default:** a sensible default where one exists (optional).
```

Pick a short, stable `Q-XXX` slug — it gets cited from decisions, branches, and PRs, so
don't rename it casually. If several questions are tightly coupled, a combined heading like
`Q-HIVE / Q-GRAN` is fine.

## Resolving / closing a question

1. **Settle the answer with the user** if it changes a `D-*` or a requirement — those need
   confirmation (mandatory-workflow). An unresolved `Q-*` must not be silently assumed away.
2. **Write the answer in its place of record** (table above) and make that artifact **cite
   the `Q-*` ID** (e.g. add `**Supersedes:** Q-XXX` to the decision).
3. **Remove the `Q-*` entry** from `open-questions.md`.
4. **Re-point references:** update any docs that linked to the removed `Q-*` so they point
   at the resolving `D-*` instead — a removed heading anchor would otherwise dangle.
5. **Commit the removal together with the artifact that now holds the answer**, so the file
   is never in a state where a question is "answered but still listed."

### Partially resolved → narrow, don't remove

If a decision settles only part of a `Q-*`, **keep the entry but shrink it** to what's still
open, and note what was decided and where. Example: `Q-SYNC` — the sync *engine* is chosen
(D-6) and *write-back integrity* is decided (D-12), but the conflict policy and atomicity
mechanism remain, so the entry stays, narrowed to those.

### Deferred ≠ resolved

A question that's postponed (not answered) **stays in the file**, marked deferred with the
**trigger to revisit** — e.g. `Q-LLM — ⏭️ DEFERRED to the native phase (SP-2)`. Don't remove
it; it's still open, just not now.

## Why this is worth the discipline

An "open questions" list you can trust to be *only* open questions is what makes planning
fast and honest — you read it top-to-bottom as "what we still owe a decision." Keeping
resolved stubs around for "traceability" trades that away for a duplicate of information the
`D-*` already holds better. Optimize for the live list; let `decisions.md` and git be the
archive.
