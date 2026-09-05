---
description: Orchestrate building a brand-new capability end to end — requirements, plan, TDD, review, gated commit, PR. Wrapper that kicks off the project orch-add-feature skill.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# /orch-add-feature

Manually launch the **orch-add-feature** orchestrator: a gated
Requirements → Plan → TDD → Review → Commit → Land pipeline for net-new capability.

## Usage

```text
/orch-add-feature <what to add>
```

Examples:

```text
/orch-add-feature add hive inspection notes to the apiary detail screen (#231)
/orch-add-feature support CSV export of inspection history in the admin app
```

## What It Does

**Invoke the project skill `orch-add-feature` in `.claude/skills/`** with `$ARGUMENTS` as the
request — not ECC's copy of the same name. The skill (via the shared `orch-pipeline` engine, also
in `.claude/skills/`) will:

1. Classify size and state the tier in one line.
2. Read `requirements/` for the `FR-*`/`NFR-*`, `D-*` and any blocking `Q-*` the feature touches,
   and read the story with `gh issue view <n>`. **Stop and ask** if the feature contradicts a `D-*`
   or an open `Q-*` blocks it. Reuse search (GitHub, vendor docs, registries) only if new tech or a
   new dependency is involved.
3. Plan a task list of thin vertical slices. → **GATE 1** (approve the plan).
4. TDD each slice (new failing tests → green), then `code-reviewer` plus the reviewers the diff
   paths select, plus `security-reviewer` on a security trigger.
5. `task lint` and `task test` green locally, then commit as conventional `feat:` commits.
   → **GATE 2** (confirm before commit).
6. Land: push, CI green, open the PR from `.github/PULL_REQUEST_TEMPLATE.md` with the Definition of
   Done filled truthfully and every Before-merge item either done now or opened as a GitHub Issue
   in this session and linked. → **GATE 3** (confirm the PR body before push).

Honor all three gates — no implementation before Gate 1, no commit before Gate 2, no push or PR
before Gate 3.

Do **not** invoke ECC's `/epic-*` commands or `/projects` from this flow; coordination stays on
native GitHub fields (claiming = the assignee field).

If `$ARGUMENTS` is empty, ask the user what capability to add.
