---
name: orch-fix-defect
description: >-
  Orchestrate fixing a bug — reproduce it as a new failing regression test, fix to green, review,
  gated commit, then land the PR — by delegating each phase to the matching project agent. Use when
  existing behavior is broken or wrong: a crash, an error, a regression, or output that does not
  match what the requirement says it should be.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# orch-fix-defect

Actor · action · target: **orch · fix · defect**. Thin wrapper over the shared engine in
[`orch-pipeline`](../orch-pipeline/SKILL.md).

## When to Use

- Something is **broken**: wrong output, an error, a crash, a regression.
- Distinguish from siblings:
  - behavior is correct but you want it different → `orch-change-feature`.
  - the capability does not exist yet → `orch-add-feature`.

## Operation settings

- **Default size floor:** small (often trivial).
- **Phase mask:** 0 → 1 → (light 2 only if the root cause is non-obvious or the tier is standard+)
  → 4 → 5 → 6 → 7.
- **First move (phase 4):** reproduce the bug as a **new failing** regression test, then fix until
  it goes green. Proving the bug exists first is what separates a fix from a tweak.

## How It Works

1. Run the `orch-pipeline` engine with the settings above.
2. If the root cause is unclear, scope it with `code-explorer` before writing the red test.
   Escalate build breaks to `go-build-resolver` (Go) or `dart-build-resolver` (Dart/Flutter);
   `admin/` build breaks go back through the implement loop plus `task web:lint`.
3. **Phase 1 still runs — trimmed but not skipped.** Before declaring something a defect, confirm
   what the correct behavior actually is: find the `FR-*`/`NFR-*` it violates and the `D-*` that
   governs it in `requirements/`, and read the bug's issue with `gh issue view <n>`. A "bug" that
   turns out to match the spec is a change request, not a fix. Reuse search is a sub-step only in
   the rare case the fix needs new tech or a new dependency.
4. **Stop and ask** if the fix as scoped would contradict a `D-*`, or if an open `Q-*` means the
   correct behavior is not yet decided. That is a stop condition, not a gate.
5. Stop at **Gate 1** (only if a plan was produced), **Gate 2** (pre-commit) and **Gate 3** (PR
   body, before push).
6. Review with `code-reviewer` plus the reviewers the diff paths select (`services/**` →
   `go-reviewer`, `client/**` → `flutter-reviewer`, `admin/**` → `react-reviewer`, migrations/SQL →
   `database-reviewer`, `contracts/**` → `contracts-reviewer`, `infra/**` → `infra-reviewer`). Add
   `security-reviewer` if the defect sits in a security-sensitive path — auth, `services/identity/`,
   authentik blueprints, sync validation rules, tenancy scoping, input handling, DB queries,
   secrets.
7. At **Phase 7 — Land**, `task lint` and `task test` green locally then CI green, open the PR from
   `.github/PULL_REQUEST_TEMPLATE.md`, fill the Definition of Done truthfully, and resolve every
   Before-merge item: done now if small and adjacent, otherwise opened as a GitHub Issue in this
   session and linked. A "we should also harden X" realisation from the fix becomes an Issue now,
   not a note.

## Example

```text
orch-fix-defect: a queued delete loses its LWW timestamp across an app restart (#276)
→ requirements/: FR-OF-1, D-12 — confirm the correct behavior, then gh issue view 276
→ write a failing regression test that restarts the queue and asserts the timestamp
→ fix to green → code-reviewer + flutter-reviewer (+ security-reviewer: sync validation)
→ task lint && task test green → commit fix:  [GATE 2: confirm]
→ PR from template, DoD filled, Before-merge resolved  [GATE 3: confirm]
```
