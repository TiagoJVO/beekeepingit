---
name: orch-change-feature
description: >-
  Orchestrate altering an existing, working feature to new desired behavior — update its tests to
  the new spec first, change the implementation to match, review, gated commit, then land the PR.
  Use when the user says "change", "adjust", "instead of X do Y", or "make it also …" about
  something that already works correctly; not for bugs and not for capability that does not exist.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# orch-change-feature

Actor · action · target: **orch · change · feature**. Thin wrapper over the shared engine in
[`orch-pipeline`](../orch-pipeline/SKILL.md).

## When to Use

- An existing feature **works**, but the desired behavior is different ("change", "adjust", "make
  it also …", "instead of X do Y").
- Distinguish from siblings:
  - **not** broken → not `orch-fix-defect` (there is no bug to reproduce).
  - **not** new → not `orch-add-feature` (the capability already exists).

## Operation settings

- **Default size floor:** small — most tweaks are a function or two.
- **Phase mask:** 0 → 1 → (light 2) → 4 → 5 → 6 → 7.
- **First move (phase 4):** update the _existing_ tests to express the new desired behavior, then
  change the implementation until they pass. Changing the tests first is what separates a tweak
  from a fix.

## How It Works

1. Run the `orch-pipeline` engine with the settings above.
2. Keep the plan light — only `standard`+ size warrants a full `planner` pass. Scope the existing
   behavior with `code-explorer` when the current implementation is unfamiliar.
3. **Phase 1 still runs, even for a small tweak.** A behavior change is exactly the kind of thing
   a `D-*` decision or an `FR-*` pins down: read `requirements/` for the requirement the current
   behavior implements and the decisions around it, and read the issue with `gh issue view <n>`.
   Reuse search is a sub-step only if the new behavior brings in new tech or a dependency.
4. **Stop and ask** if the requested new behavior contradicts a `D-*` or a requirement, or if an
   open `Q-*` blocks it — a change request is the most common way this happens. On confirmation,
   update the decision/requirement in the same change. That is a stop condition, not a gate.
5. Stop at **Gate 1** (plan / changed-test approval), **Gate 2** (pre-commit) and **Gate 3** (PR
   body, before push).
6. Review with `code-reviewer` plus the reviewers the diff paths select (`services/**` →
   `go-reviewer`, `client/**` → `flutter-reviewer`, `admin/**` → `react-reviewer`, migrations/SQL →
   `database-reviewer`, `contracts/**` → `contracts-reviewer`, `infra/**` → `infra-reviewer`). Add
   `security-reviewer` on a security trigger — auth, `services/identity/`, authentik blueprints,
   sync validation rules, tenancy scoping, input handling, DB queries, secrets.
7. At **Phase 7 — Land**, `task lint` and `task test` green locally then CI green, open the PR from
   `.github/PULL_REQUEST_TEMPLATE.md`, fill the Definition of Done truthfully, and resolve every
   Before-merge item: done now if small and adjacent, otherwise opened as a GitHub Issue in this
   session and linked.

## Example

```text
orch-change-feature: queued deletes should win over a newer remote edit, not lose (#276)
→ requirements/: FR-OF-1, D-12 (LWW) — confirm the change does not contradict D-12
→ update the existing LWW tests to the new spec  [GATE 1: approve]
→ change impl to green → code-reviewer + go-reviewer + flutter-reviewer
  (+ security-reviewer: sync validation rules)
→ task lint && task test green → commit fix:/feat: as appropriate  [GATE 2: confirm]
→ PR from template, DoD filled, Before-merge resolved  [GATE 3: confirm]
```
