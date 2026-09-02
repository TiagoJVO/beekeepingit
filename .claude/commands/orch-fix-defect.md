---
description: Orchestrate fixing a bug — reproduce it as a failing regression test, fix to green, review, gated commit, PR. Wrapper for the project orch-fix-defect skill.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# /orch-fix-defect

Manually launch the **orch-fix-defect** orchestrator: prove the bug with a red test, then fix to
green.

## Usage

```text
/orch-fix-defect <what is broken>
```

Examples:

```text
/orch-fix-defect a queued delete loses its LWW timestamp across an app restart (#276)
/orch-fix-defect the apiary list returns 500 when the org has no apiaries yet
```

## What It Does

**Invoke the project skill `orch-fix-defect` in `.claude/skills/`** with `$ARGUMENTS` as the
request — not ECC's copy of the same name. The skill (via the shared `orch-pipeline` engine, also
in `.claude/skills/`) will:

1. Classify size (default floor: small, often trivial); scope the root cause with `code-explorer`
   if it is unclear.
2. Confirm what the correct behavior actually is: read `requirements/` for the `FR-*`/`NFR-*` the
   defect violates and the `D-*` that governs it, and read the bug's issue with
   `gh issue view <n>`. A "bug" that turns out to match the spec is a change request, not a fix.
   **Stop and ask** if the fix would contradict a `D-*` or an open `Q-*` means the correct behavior
   is not yet decided.
3. **Write a new failing regression test** reproducing the bug, then fix until it goes green.
   (Proving the bug first is what makes this a fix, not a tweak.) → **GATE 1** applies only if a
   plan was produced.
4. `code-reviewer` plus the reviewers the diff paths select, plus `security-reviewer` if the defect
   sits in a sensitive path (auth, `services/identity/`, authentik blueprints, sync validation
   rules, tenancy scoping).
5. `task lint` and `task test` green locally, then commit as a conventional `fix:` commit.
   → **GATE 2** (confirm before commit).
6. Land: push, CI green, open the PR from `.github/PULL_REQUEST_TEMPLATE.md` with the Definition of
   Done filled truthfully and every Before-merge item either done now or opened as a GitHub Issue
   in this session and linked — a "we should also harden X" realisation becomes an Issue now, not a
   note. → **GATE 3** (confirm the PR body before push).

Use this only when behavior is **broken/wrong** — not for intentional changes
(`/orch-change-feature`) or new capability (`/orch-add-feature`).

Do **not** invoke ECC's `/epic-*` commands or `/projects` from this flow; coordination stays on
native GitHub fields (claiming = the assignee field).

If `$ARGUMENTS` is empty, ask the user to describe the defect.
