---
description: Orchestrate altering an existing, working feature to new desired behavior — update tests to the new spec, change impl, review, gated commit, PR. Wrapper for the project orch-change-feature skill.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# /orch-change-feature

Manually launch the **orch-change-feature** orchestrator: change behavior that already works to a
new desired spec, tests-first.

## Usage

```text
/orch-change-feature <the new desired behavior>
```

Examples:

```text
/orch-change-feature a queued delete should win over a newer remote edit, not lose (#276)
/orch-change-feature instead of sorting apiaries by name, sort by last inspection date
```

## What It Does

**Invoke the project skill `orch-change-feature` in `.claude/skills/`** with `$ARGUMENTS` as the
request — not ECC's copy of the same name. The skill (via the shared `orch-pipeline` engine, also
in `.claude/skills/`) will:

1. Classify size (default floor: small) and state the tier.
2. Read `requirements/` for the requirement the current behavior implements and the `D-*` around
   it, and read the issue with `gh issue view <n>`. **Stop and ask** if the requested behavior
   contradicts a `D-*` or a requirement, or if an open `Q-*` blocks it — a change request is the
   most common way that happens; on confirmation the decision is updated in the same change.
3. Light plan only if the new behavior needs one. → **GATE 1** (approve the changed-test plan).
4. **Update the existing tests** to express the new behavior, then change the implementation until
   they pass. (Changing the tests first is what makes this a tweak, not a fix.)
5. `code-reviewer` plus the reviewers the diff paths select, plus `security-reviewer` on a security
   trigger. `task lint` and `task test` green, then commit. → **GATE 2**.
6. Land: push, CI green, open the PR from `.github/PULL_REQUEST_TEMPLATE.md` with the Definition of
   Done filled truthfully and every Before-merge item either done now or opened as a GitHub Issue
   in this session and linked. → **GATE 3** (confirm the PR body before push).

Use this only when the feature **works** but should behave differently — not for bugs
(`/orch-fix-defect`) or net-new capability (`/orch-add-feature`).

Do **not** invoke ECC's `/epic-*` commands or `/projects` from this flow; coordination stays on
native GitHub fields (claiming = the assignee field).

If `$ARGUMENTS` is empty, ask the user what behavior should change.
