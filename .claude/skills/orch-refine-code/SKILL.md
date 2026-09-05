---
name: orch-refine-code
description: >-
  Orchestrate a behavior-preserving refactor — confirm the existing tests are green, restructure
  without changing behavior, keep them green, review, gated commit, then land the PR. Use when the
  ask is to extract, split, rename, deduplicate, or delete dead code and the observable behavior
  must stay exactly the same; if behavior is meant to change at all, use a sibling skill instead.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# orch-refine-code

Actor · action · target: **orch · refine · code**. Thin wrapper over the shared engine in
[`orch-pipeline`](../orch-pipeline/SKILL.md).

## When to Use

- Same behavior, **better structure**: extract modules, remove duplication, kill dead code, reduce
  nesting, rename for clarity.
- Distinguish from siblings: if behavior is meant to change at all, this is the wrong skill
  (`orch-change-feature` / `orch-fix-defect`).

## Operation settings

- **Default size floor:** standard — restructures touch multiple files.
- **Phase mask:** 0 → 1 → 2 (plan the restructure) → 4 (keep green) → 5 → 6 → 7. No new behavior
  tests are written — the existing suite is the safety net.
- **First move (phase 4):** confirm the relevant tests exist and are **green before** touching
  code; if coverage is thin, add characterization tests first. Then restructure in small steps,
  re-running the tests after each.

## How It Works

1. Run the `orch-pipeline` engine with the settings above.
2. Map the current shape with `code-explorer` and `docs/CODEMAPS/` before planning the move.
3. **Phase 1 is lighter here but still runs.** A refactor must not quietly undo a decision: check
   `requirements/` for any `D-*` that pins the current structure (service decomposition, module
   boundaries, the shared library vs. service split) and read the tracking issue with
   `gh issue view <n>`. Reuse search applies only if the restructure introduces a library.
4. **Stop and ask** if the restructure would contradict a `D-*` — for example moving code across a
   service boundary that `docs/architecture/service-decomposition.md` and a decision fix in place.
   That is a stop condition, not a gate.
5. **Dead-code and duplication sweeps run on this repo's own gate, not on ECC's JS tooling.** Use
   `task lint` (which fans out to `golangci-lint`, `dart analyze`, the web lint, repo hygiene) plus
   targeted `grep`/`rg` for unreferenced symbols. There is no `knip` / `ts-prune` / `depcheck`
   default here — do not introduce one as part of a refactor.
6. Stop at **Gate 1** (restructure plan), **Gate 2** (pre-commit) and **Gate 3** (PR body, before
   push).
7. Review with `code-reviewer` plus the reviewers the diff paths select (`services/**` →
   `go-reviewer`, `client/**` → `flutter-reviewer`, `admin/**` → `react-reviewer`, migrations/SQL →
   `database-reviewer`, `contracts/**` → `contracts-reviewer`, `infra/**` → `infra-reviewer`). Add
   `security-reviewer` if the restructure moves code in a security-sensitive path — auth,
   `services/identity/`, authentik blueprints, sync validation rules, tenancy scoping.
8. Commit as `refactor:` — the diff must be behavior-neutral, and the proof of that is the
   unchanged test suite still green.
9. At **Phase 7 — Land**, `task lint` and `task test` green locally then CI green, open the PR from
   `.github/PULL_REQUEST_TEMPLATE.md`, fill the Definition of Done truthfully (most behavior boxes
   will be struck through with "no behavior change" — say so), and resolve every Before-merge item:
   done now if small and adjacent, otherwise opened as a GitHub Issue in this session and linked.

## Example

```text
orch-refine-code: extract the sync conflict resolver out of the queue repository (client/)
→ requirements/: D-12 (LWW) and the offline decisions still hold — no D-* contradicted
→ confirm the existing sync tests are green → plan the extraction  [GATE 1: approve]
→ move in small steps, task dart:test green after each → task lint
→ code-reviewer + flutter-reviewer → commit refactor:  [GATE 2: confirm]
→ PR from template, DoD filled, Before-merge empty → section deleted  [GATE 3: confirm]
```
