# Rule: Mandatory workflow (read before any task)

Binding for every planning or implementation task. `requirements/` is the **source of truth**
(intent); the plan/backlog lives in **GitHub Issues**; `docs/` documents what's actually built.

## 1. When planning a task, look it up in `requirements/` first

Don't work from memory. Before planning, search `requirements/` for everything the task touches:

- the **requirements** it implements (`FR-*/NFR-*`),
- the **decisions** it relies on or touches (`D-*` in `decisions.md`),
- any **open questions** it must clarify first (`Q-*` in `open-questions.md`),
- relevant **context** and intended approach (`context.md`, `tech-stack.md`).

Also read the task's epic/story in GitHub Issues (`gh issue list`; epics carry `type/epic`).
For the non-obvious conventions of that folder, see the **`requirements-folder` skill**.

## 2. Decisions & requirements are the default — but revisitable

- Treat `D-*` decisions and requirements — including rollout phase and deferred scope
  (e.g. `D-10`, `D-4`) — as the working default.
- If contradicting one genuinely makes sense, **stop and propose it to the user**. On
  confirmation, **update** the decision/requirement (note it). Never silently diverge.
- If an unresolved `Q-*` blocks the task, surface it.

Finishing a task (tests, docs, traceability, tenancy, security) is governed by
[`definition-of-done.md`](definition-of-done.md).
