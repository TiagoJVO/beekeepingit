---
name: verification-loop
description: >-
  Run BeekeepingIT's local quality gate — task lint, task test, task build, plus task openapi:lint
  when contracts changed and helm lint when infra changed — and produce a PASS/FAIL verification
  report. Use after finishing a feature or a significant change, before committing or opening a PR,
  after a refactor, or any time you need to know whether the branch would survive CI.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# Verification Loop

A comprehensive local verification pass for a BeekeepingIT branch. CI runs the same gate
(`task ci` = `task lint` + `task test`) and fails the whole job on a single unformatted file, so
running this locally costs seconds where a CI round-trip costs many minutes.

## When to Use

- After completing a feature or a significant code change
- Before committing (Gate 2) and before opening a PR (Gate 3) in the `orch-*` pipeline
- After a refactor, to prove behavior is unchanged
- Any time you want to know whether the branch would go green in CI

## Verification Phases

Run from the repo root (or the worktree root). Everything below assumes a POSIX shell — WSL2 on
Windows — and the `mise` toolchain pins being active.

### Phase 1: Scope the diff

Know which conditional phases apply before running anything.

```bash
git diff --name-only HEAD
git diff --stat
```

- any path under `contracts/` → Phase 5 (OpenAPI) applies
- any path under `infra/helm/` → Phase 6 (Helm) applies
- `services/**` / `client/**` / `admin/**` tell you which language legs actually have work

### Phase 2: Lint

`task lint` is the aggregate gate: repo hygiene (Prettier check, markdownlint, actionlint,
shellcheck, gitleaks, the repo-map and deploy-URL checks) plus every language linter.

```bash
task lint 2>&1 | tail -40
```

Scope it while iterating, then run the aggregate before you report:

```bash
task repo:lint        # formatting + Markdown + Actions + shell + secrets
task go:lint          # golangci-lint          (task go:lint -- <dir> to scope)
task dart:lint        # flutter/dart analyze + format check
task web:lint         # admin app lint
```

If lint fails on formatting only, `task format` writes the fixes; re-run `task lint`.

### Phase 3: Tests

```bash
task test 2>&1 | tail -60
```

Fans out to `task go:test`, `task web:test`, `task dart:test`. Scope a leg while iterating
(`task go:test -- services/identity`), but the report must be based on the aggregate run.

Report totals per leg: tests run, passed, failed, skipped. **There is no coverage threshold in this
repo** — the bar is the Definition of Done checklist in `.github/PULL_REQUEST_TEMPLATE.md`
("Tests added/updated and passing in CI"), not a percentage.

### Phase 4: Build

```bash
task build 2>&1 | tail -30
```

Fans out to `task go:build`, `task web:build`, `task dart:build`. A green test run with a red
build is still a FAIL.

### Phase 5: Contracts (only if `contracts/` changed)

```bash
task openapi:lint 2>&1 | tail -30
task openapi:breaking-diff 2>&1 | tail -30    # fails on a breaking change vs origin/main
```

### Phase 6: Helm (only if `infra/helm/` changed)

There is no `task` wrapper for these — run them the way `.github/workflows/helm-ci.yml` does:

```bash
cd infra/helm/beekeepingit && helm dependency build . && helm lint .
for env in dev staging prod; do helm lint . -f "environments/$env.yaml"; done
helm template beekeepingit .
```

Repeat in `infra/helm/observability` if that chart changed (its dependencies are remote, so its
`helm dependency build` needs network).

### Phase 7: Security scan

`task repo:secrets` (gitleaks) already runs inside `task lint`. Add the Go vulnerability scan when
Go code or its dependencies changed, and eyeball the diff for debug leftovers:

```bash
task go:vuln 2>&1 | tail -20
git diff HEAD | grep -nE '(fmt\.Print|log\.Print|console\.log|print\()' | head -20
```

### Phase 8: Diff review

```bash
git diff --stat
git diff HEAD --name-only
```

Review each changed file for unintended changes, missing error handling, and edge cases — and for
the Definition-of-Done items a linter cannot see: offline/sync behavior, EN/PT strings
externalized, accessibility, `organization_id` tenancy scoping, history recorded for entity
changes.

## Output Format

After running the applicable phases, produce a verification report:

```text
VERIFICATION REPORT
===================

Lint (task lint):        [PASS/FAIL] (X issues)
Tests (task test):       [PASS/FAIL] (go X/Y, dart X/Y, web X/Y)
Build (task build):      [PASS/FAIL]
Contracts (openapi):     [PASS/FAIL/N-A] (task openapi:lint, breaking-diff)
Helm (infra):            [PASS/FAIL/N-A] (helm lint + template)
Security:                [PASS/FAIL] (gitleaks via repo:lint, govulncheck, X issues)
Diff:                    [X files changed]

Overall:   [READY/NOT READY] for commit / PR

Issues to Fix:
1. ...
2. ...
```

Mark a conditional phase `N-A` only when Phase 1 showed its paths were untouched — never because it
was skipped for time. `Overall: READY` requires every applicable phase PASS; anything unrun makes
the report NOT READY, not READY-with-caveats.

## Continuous Mode

For long sessions, verify at natural checkpoints rather than only at the end:

- after finishing a function or a widget
- after a slice goes green in the TDD loop
- before moving to the next task in the plan

A scoped `task go:test -- <dir>` is cheap enough to run continuously; save the full `task lint` +
`task test` for the checkpoint before Gate 2.

## Relationship to the gates and hooks

This skill is what makes the `orch-pipeline` Gate 2 and Gate 3 claims true: "green locally, then
CI green". `lefthook` git hooks catch issues at commit time; this skill is the deliberate,
whole-branch pass. Neither replaces CI — but a clean run here means CI should have nothing new to
say.
