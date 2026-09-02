---
name: orch-pipeline
description: >-
  Shared orchestration engine for the orch-* skill family. Defines the gated
  Intake → Requirements → Plan → TDD → Review → Commit → Land pipeline, the size classifier,
  the phase masks, the agent map, the security trigger, and the three human gates that the
  orch-* operation skills delegate to. Read directly only when adding a new operation to the
  family or tuning the shared phases, gates, or agent map — otherwise invoke an operation skill
  (orch-add-feature, orch-change-feature, orch-fix-defect, orch-refine-code).
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# Orchestrator Pipeline (shared engine)

The `orch-*` skills are thin wrappers. They do not re-implement any work — they classify the
request, choose which phases of _this_ pipeline run, and delegate each phase to a project agent.
This file is that pipeline.

> Invoke an operation skill (`orch-add-feature`, `orch-fix-defect`, …) rather than this engine
> directly. This file is the reference they point at.

## When to Use

- Loaded indirectly whenever an `orch-*` operation skill runs.
- Read directly only when adding a new operation to the family or tuning the shared phases,
  gates, or agent map.

## The operation family

| Skill                 | Operation | Trigger                             | First move                              |
| --------------------- | --------- | ----------------------------------- | --------------------------------------- |
| `orch-add-feature`    | feature   | capability does not exist yet       | requirements + plan a new slice         |
| `orch-change-feature` | tweak     | works, but desired behavior differs | amend existing behavior _and its tests_ |
| `orch-fix-defect`     | fix       | broken; behavior is wrong           | reproduce as a failing test, then fix   |
| `orch-refine-code`    | refactor  | behavior stays, structure improves  | restructure while keeping tests green   |

These wrappers add the shared size classifier, the phase masks, and the three gates on top of the
project's own agents and rules, so one umbrella covers all four operations consistently.

## Step 0 — Classify size (right-sizing)

Ceremony scales to blast radius. Score the request on three signals, take the **highest** tier any
signal reaches, and state the result in one line so the user can override:

| Tier     | Files touched        | New dependency / contract                            | Design ambiguity             | Phases that run               |
| -------- | -------------------- | ---------------------------------------------------- | ---------------------------- | ----------------------------- |
| trivial  | 1, a few lines       | none                                                 | none — the change is obvious | 1 → 4 → 5 → 6 → 7             |
| small    | 1 file / 1 unit      | none                                                 | clear once you read the code | 1 → (2 light) → 4 → 5 → 6 → 7 |
| standard | 2–5 files            | maybe a new internal module                          | one real choice to make      | 1 → 2 → 4 → 5 → 6 → 7         |
| large    | many / cross-cutting | new external dep, public API/contract, or a spec doc | multiple open questions      | 1 → 2 → (3) → 4 → 5 → 6 → 7   |

Phase 0 (Intake) always runs and is omitted from the mask column above. Phase 1 also always runs —
even a trivial change needs its requirement / decision / issue context (below). The tie-breaker:
anything touching a security trigger (below), a published contract under `contracts/`, a DB
migration, or tenancy scoping is **at least** standard, regardless of file count.

## The phases

Each phase delegates — it does not do the work inline.

### 0. Intake

Restate the request. Identify which operation it is and, if there is one, which GitHub issue it
belongs to.

### 1. Requirements & context

**This replaces ECC's generic "Research & Reuse" phase.** Per
[`.claude/rules/mandatory-workflow.md`](../../rules/mandatory-workflow.md) — read it —
`requirements/` is the source of truth for intent; never work from memory.

1. Search `requirements/` for everything the task touches: the `FR-*`/`NFR-*` it implements, the
   `D-*` decisions in `decisions.md` it relies on or touches, any `Q-*` in `open-questions.md` it
   must clear first, plus `context.md` and `tech-stack.md`. The `requirements-folder` skill has
   that folder's non-obvious conventions.
2. Read the story/epic: `gh issue view <n>` (and `gh issue list`; epics carry `type/epic`). Epics
   track children through the Sub-issues panel — read that, not a prose checklist.
3. Read the as-built side for what you are about to touch: `docs/` and the token-lean
   `docs/CODEMAPS/`.
4. _Sub-step, only when new tech or a new dependency is involved:_ reuse search — GitHub code/repo
   search, then vendor/library docs, then the package registry (Go modules, pub.dev, npm). Prefer
   adopting a proven implementation over net-new code. Skip this entirely for work inside the
   existing stack and dependencies; it is not a phase of its own here.

**Stop condition (a stop, not a gate):** if the task as asked would contradict a `D-*` decision or
a requirement, or if an unresolved `Q-*` blocks it, **stop and put it to the user**. Do not
silently diverge and do not assume an answer. On confirmation, update the decision/requirement in
the same change.

### 2. Plan

Delegate to the `planner` agent (or `code-architect` for structural decisions). Output an ordered
task list of thin vertical slices, each carrying its `FR-*`/`NFR-*`/`D-*` and issue reference.
→ **GATE 1.**

### 3. Scaffold

Large only: stand up the first end-to-end slice before fanning out.

### 4. Implement (TDD)

Drive each task through the `tdd-guide` agent: red → green → refactor. Honor the operation's
first-move rule. Escalate a broken build to the matching build resolver (agent map below). Keep
offline/sync paths, EN/PT i18n externalization, accessibility, and `organization_id` tenancy in
scope as you go — they are Definition-of-Done items, not afterthoughts.

### 5. Review

`code-reviewer` plus the language/domain reviewers selected by diff path (agent map below), and
`security-reviewer` on a security trigger. `/orch-review` runs this phase as a native Workflow
with dedup + adversarial verification. CRITICAL and HIGH findings must be resolved before Gate 2.

### 6. Commit

Conventional Commits (`feat:` / `fix:` / `refactor:` / `docs:` / `test:` / `chore:` / `ci:`), one
per logical chunk, referencing the requirement IDs, decisions, and issue per `CONTRIBUTING.md`.
→ **GATE 2.**

### 7. Land

Open the PR and clear what it owes — see the next section.

## Phase 7 — Land

Committing is not landing. After Gate 2:

1. **Verify green.** `task lint` and `task test` pass locally (see "Verification"), then push the
   branch and confirm CI is green. CI runs the same gate; one unformatted file fails the whole job.
2. **Open the PR with `.github/PULL_REQUEST_TEMPLATE.md`** — read that template file and use it
   verbatim. Fill in Summary, Related issues (with `Closes #`, the `FR-*`/`NFR-*` and `D-*` IDs),
   Type of change, and How this was tested.
3. **Fill the Definition of Done section truthfully.** It is the bar for this repo — that
   checklist, not a coverage percentage, is what "done" means here. Tick only what is actually
   true; strike through what does not apply and say why in one clause. An unticked box is
   information; a falsely ticked box is a defect.
4. **Resolve the "Before merge" section — nothing is parked.** For every item this PR still owes,
   exactly one of:
   - **Do it now** if it is small (< ~30 min) and adjacent to the diff already in hand.
   - **Open a GitHub Issue for it in this session** — `gh issue create`, shaped per the
     `backlog-management` skill (native fields only: type via the `type/*` label, parent via the
     Sub-issues panel, milestone via the Milestone field; `FR-*`/`NFR-*`/`D-*`/`Q-*` traceability
     IDs do stay in the body) — and link it from the PR's Before-merge list.

   Do not leave an item as a bare note in the PR body, a `TODO`, a code comment, or a file. If the
   section ends up owing nothing, delete it as the template instructs.

5. → **GATE 3.**

## The three gates

This family is **gated, not autonomous**:

1. **GATE 1 — after Plan.** Present the task list; do not write implementation code until the user
   approves.
2. **GATE 2 — before Commit.** Present the diff summary and the proposed commit messages; do not
   commit until the user confirms.
3. **GATE 3 — before push / PR.** Present the PR body — the filled Definition of Done, and the
   Before-merge list with each item either already done or carrying its GitHub Issue link. Do not
   push or open the PR until the user confirms.

Everything between the gates flows without stopping. The Phase 1 requirements/decision conflict is
a separate **stop condition**, not a gate: it can fire before Gate 1 and needs a user answer to
continue at all.

## Agent map

Only agents that exist for this repo. Match the reviewer to the **diff path**, not to a guessed
project language — this is a polyglot monorepo and one PR often spans several.

| Phase               | Primary                                                                 | Fallback / escalation                                                         |
| ------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Intake / understand | `code-explorer` — trace existing paths before a tweak, fix, or refactor | read `docs/CODEMAPS/` first for orientation                                   |
| Plan                | `planner`                                                               | `code-architect` for structural calls                                         |
| Implement           | `tdd-guide`                                                             | build breaks → `go-build-resolver` (Go), `dart-build-resolver` (Dart/Flutter) |
| Review              | `code-reviewer` (always)                                                | plus the path-selected reviewers below                                        |
| Security            | `security-reviewer`                                                     | on the security trigger below                                                 |

Path-selected reviewers, additive — run every one whose paths the diff touches:

| Diff path                           | Reviewer             |
| ----------------------------------- | -------------------- |
| `services/**`                       | `go-reviewer`        |
| `client/**`                         | `flutter-reviewer`   |
| `admin/**`                          | `react-reviewer`     |
| any migration / SQL / `sqlc` change | `database-reviewer`  |
| `contracts/**`                      | `contracts-reviewer` |
| `infra/**`                          | `infra-reviewer`     |

> If a path-selected reviewer is not installed in the current environment, say so and fall back to
> `code-reviewer` for that path rather than silently dropping the dimension.

There is no React build resolver here — a broken `admin/` build goes back through the normal
implement loop plus `task web:lint` / `task build`, not to a resolver agent.

## Security-review trigger

Pull in `security-reviewer` when the diff touches any of:

- authentication or authorization — including **anything under `services/identity/`** or the
  **authentik blueprints**
- **sync validation rules** — the boundary contract / queued-edit revalidation paths
- **tenancy scoping** — anything that reads, writes, or filters on `organization_id`
- user-input handling, database queries, file-system paths, external API calls
- cryptography, secrets, or credentials

## Do not invoke the ECC epic commands

Coordination in this repo lives on **native GitHub fields**. Never invoke ECC's `/epic-claim`,
`/epic-sync`, `/epic-validate`, `/epic-publish`, `/epic-decompose`, `/epic-review`,
`/epic-unblock`, or `/projects` from this pipeline — they write a custom coordination block and
`coordination:*` labels into issue bodies, which is exactly the prose duplication the
`backlog-management` skill forbids.

**Claiming a story = assigning yourself with the native assignee field**
(`gh issue edit <n> --add-assignee @me`). Status lives on the Project board; parentage lives in
the Sub-issues panel; dependencies live in blocked-by relationships. None of that goes in an issue
body.

## Handoff artifacts

The pipeline carries no hidden state:

- The Phase 1 findings (requirement IDs, decisions, issue number) are quoted in the plan, the
  commits, and the PR — that traceability chain _is_ the handoff.
- The Phase 2 task list drives the Implement loop.
- Review findings (CRITICAL / HIGH) must be resolved before Gate 2.
- Anything the change still owes goes in the PR's Before-merge section and is resolved at Phase 7
  — done now, or an Issue opened this session.

## Verification

- size tier was stated and matched the work
- Phase 1 ran: requirement IDs, decisions and the issue were actually read, not recalled; a `D-*`
  contradiction or a blocking `Q-*` was surfaced to the user rather than assumed
- Gates 1, 2 and 3 were all honored
- `security-reviewer` ran iff a security trigger was touched, and every path-selected reviewer ran
  for the paths the diff touches
- commits are conventional, scoped to one logical change, and cite `FR-*`/`NFR-*`/`D-*`/`#`
- new / changed behavior has tests, and **`task lint` and `task test` are green locally, then CI
  is green**. That — not a coverage percentage — is the gate.
- the PR uses `.github/PULL_REQUEST_TEMPLATE.md`, its Definition of Done section is filled
  truthfully, and its Before-merge section is empty or fully resolved into linked Issues
