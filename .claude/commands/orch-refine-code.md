---
description: Orchestrate a behavior-preserving refactor — confirm tests green, restructure without changing behavior, keep green, review, gated commit, PR. Wrapper for the project orch-refine-code skill.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# /orch-refine-code

Manually launch the **orch-refine-code** orchestrator: improve structure while behavior stays
identical, with the existing test suite as the safety net.

## Usage

```text
/orch-refine-code <what to restructure>
```

Examples:

```text
/orch-refine-code extract the sync conflict resolver out of the queue repository
/orch-refine-code remove duplication between the apiaries and identity handlers
```

## What It Does

**Invoke the project skill `orch-refine-code` in `.claude/skills/`** with `$ARGUMENTS` as the
request — not ECC's copy of the same name. The skill (via the shared `orch-pipeline` engine, also
in `.claude/skills/`) will:

1. Classify size (default floor: standard — restructures touch multiple files) and map the current
   shape with `code-explorer` plus `docs/CODEMAPS/`.
2. Check `requirements/` for any `D-*` that pins the current structure (service decomposition,
   module boundaries, the shared-library vs. service split) and read the tracking issue with
   `gh issue view <n>`. **Stop and ask** before moving code across a boundary a decision fixes in
   place.
3. Confirm the relevant tests exist and are **green before** touching code; add characterization
   tests first if coverage is thin. Plan the restructure. → **GATE 1**.
4. Restructure in small steps, re-running the tests after each (no new behavior tests — the
   existing suite proves behavior is unchanged). Dead-code and duplication sweeps run on this
   repo's own gate: **`task lint`** plus targeted `grep`/`rg` for unreferenced symbols. There is no
   `knip` / `ts-prune` / `depcheck` default here — do not introduce one as part of a refactor.
5. `code-reviewer` plus the reviewers the diff paths select, then `task lint` and `task test` green
   and commit as `refactor:` (the diff must be behavior-neutral). → **GATE 2**.
6. Land: push, CI green, open the PR from `.github/PULL_REQUEST_TEMPLATE.md` with the Definition of
   Done filled truthfully (behavior boxes struck through with "no behavior change") and every
   Before-merge item either done now or opened as a GitHub Issue in this session and linked.
   → **GATE 3** (confirm the PR body before push).

Use this only when behavior must **not** change. If behavior should change at all, use
`/orch-change-feature` or `/orch-fix-defect`.

Do **not** invoke ECC's `/epic-*` commands or `/projects` from this flow; coordination stays on
native GitHub fields (claiming = the assignee field).

If `$ARGUMENTS` is empty, ask the user what to refine.
