# Rule: Mandatory workflow (read before any task)

Binding for every planning or implementation task. **Nothing is built yet.** `requirements/`
is the **source of truth** (intent) and `planning/` is the plan — both revisable; `docs/`
documents what's actually built (empty until implementation).

## 1. During planning, read the sources of truth (no working from memory)
Read these **when planning a task** — not during implementation:
- `requirements/context.md`, `functional-requirements.md`, `non-functional-requirements.md`
- `requirements/decisions.md` (`D-*`) and `requirements/open-questions.md` (`Q-*`)
- The intended technical approach in `requirements/tech-stack.md` (see §3)
- The task's epic/story in `planning/roadmap.md` and `planning/epics/`

Identify the `FR-*/NFR-*` the task implements, the `D-*` it touches, and any `Q-*`.

## 2. Decisions & requirements are the default — but revisitable
- Treat `D-*` decisions and requirements as the working default.
- If contradicting one genuinely makes sense, **stop and propose it to the user**. On
  confirmation, **update** the decision/requirement (note it). Never silently diverge.
- If an unresolved `Q-*` blocks the task, surface it.

## 3. Intent lives in `requirements/`; `docs/` documents what's built
- Architecture **intent** is in `requirements/` (incl. `requirements/tech-stack.md`) —
  read it during planning.
- As you **implement**, document the **actual** architecture in `docs/` and record
  significant decisions as ADRs in `docs/adr/`.
- If implementation must diverge from a `D-*`/requirement, confirm with the user and
  update `requirements/` (see §2).

## 4. Respect phase & scope
- Follow the rollout order in `D-10` (PWA → Android → iOS; native only when needed).
- Don't build deferred scope (`D-4`: billing `EPIC-90`, quotas `EPIC-91`, on-device AI
  until the native phase) without a decision.

## 5. Traceability
- Reference IDs (`FR-*/NFR-*`, `D-*`, `Q-*`, `EPIC-*`, issue `#`) in branches, commits, PRs.

## 6. Quality gates
- Write/update tests with every change (`NFR-TST`). Update docs when behavior/scope changes.
- See `.claude/rules/definition-of-done.md` and `CONTRIBUTING.md` before opening a PR.
