---
name: orch-add-feature
description: >-
  Orchestrate building a brand-new capability end to end — read the requirements and the issue,
  plan, TDD, review, gated commit, then land the PR — by delegating each phase to the matching
  project agent. Use when the user asks to add, build, implement, or support something that does
  not exist yet, and it is neither a correction of broken behavior nor a change to behavior that
  already works.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# orch-add-feature

Actor · action · target: **orch · add · feature**. Thin wrapper over the shared engine in
[`orch-pipeline`](../orch-pipeline/SKILL.md).

## When to Use

- The user wants a capability that does **not exist yet** ("add", "build", "implement",
  "support …").
- It is net-new behavior — not a correction (`orch-fix-defect`) and not an alteration of existing
  behavior (`orch-change-feature`).

## Operation settings

- **Default size floor:** standard — run the full Requirements + Plan phases unless clearly small.
- **Phase mask:** 0 → 1 → 2 → 4 → 5 → 6 → 7 (skip 3 Scaffold unless the tier is large).
- **First move (phase 4):** write _new_ failing tests for the new behavior, then implement to
  green.

## How It Works

1. Run the `orch-pipeline` engine with the settings above.
2. Classify size first and state the tier in one line; small / trivial features collapse toward
   1 → 4 → 5 → 6 → 7.
3. **Phase 1 is requirements, not generic research.** Read `requirements/` for the `FR-*`/`NFR-*`
   this implements, the `D-*` it relies on, and any blocking `Q-*`; read the story with
   `gh issue view <n>`. Reuse search (GitHub, vendor docs, registries) is a sub-step only when the
   feature pulls in new tech or a new dependency — a new feature inside the existing stack does not
   need one.
4. **Stop and ask** if the feature as asked contradicts a `D-*` or is blocked by an open `Q-*`.
   That is a stop condition, not a gate.
5. Stop at **Gate 1** (plan approval), **Gate 2** (pre-commit) and **Gate 3** (PR body, before
   push).
6. Review with `code-reviewer` plus the reviewers the diff paths select (`services/**` →
   `go-reviewer`, `client/**` → `flutter-reviewer`, `admin/**` → `react-reviewer`, migrations/SQL →
   `database-reviewer`, `contracts/**` → `contracts-reviewer`, `infra/**` → `infra-reviewer`). Add
   `security-reviewer` on a security trigger — auth, `services/identity/`, authentik blueprints,
   sync validation rules, tenancy scoping, input handling, DB queries, secrets.
7. At **Phase 7 — Land**, open the PR from `.github/PULL_REQUEST_TEMPLATE.md`, fill the Definition
   of Done truthfully, and resolve every Before-merge item: done now if small and adjacent,
   otherwise opened as a GitHub Issue in this session and linked. Nothing is parked in a note.

## Example

```text
orch-add-feature: add hive inspection notes to the apiary detail screen (#231)
→ requirements/: FR-INS-2, D-10, D-12; gh issue view 231 → acceptance criteria
→ plan a task_list of vertical slices  [GATE 1: approve]
→ TDD each slice (offline queue + EN/PT strings + org scoping)
→ code-reviewer + flutter-reviewer + go-reviewer (+ security-reviewer: tenancy)
→ task lint && task test green → commit feat:  [GATE 2: confirm]
→ PR from template, DoD filled, one Before-merge item → gh issue create  [GATE 3: confirm]
```
