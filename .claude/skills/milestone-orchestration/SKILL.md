---
name: milestone-orchestration
description: >-
  How to run a fully autonomous multi-agent team against a BeekeepingIT milestone from a single
  milestone URL — research, plan, TDD, review, and merge to completion without
  stopping except for genuine requirement/decision conflicts. Use when asked to drive a milestone
  link to completion, spin up a team of agents for an M<n>, or otherwise run autonomous multi-issue
  execution across this backlog. Captures the non-obvious parts: dependencies are native (sub-issues
  + blocked-by), never inferred from prose or re-declared in a body; sequencing — within a milestone
  and across milestones alike — comes only from those native links, never from a milestone
  description; the shared local
  cluster is coordinated via infra/cluster/with-lock.sh, not a bespoke "one owner" scheme; and
  claiming/coordination must stay on native GitHub fields (assignee) — drive execution through this
  repo's own /orch-* commands and agents, never ECC's /epic-* commands or /projects, which write a
  custom coordination block + coordination:* labels into the issue body, exactly the prose
  duplication backlog-management forbids.
---

# Autonomous milestone execution (multi-agent team)

Given only a milestone URL, run a main orchestrating agent that spins up a team of implementer
agents, sequences them by real dependency, keeps the shared dev cluster from colliding, and merges
finished work — stopping only when a genuine requirement or decision question comes up. This
operationalizes **D-14**'s delivery model: milestones are thin, independently pickable per-feature
slices, and whatever ordering actually binds is expressed as native `blocked-by` links between
specific stories — _"sequencing is between stories, not epic→epic."_

## Non-obvious conventions

- **Dependencies are native — read them, never infer them.** Story-level `blocked-by` and
  epic→children `sub-issues` are the source of truth (D-14: _"sequencing is between stories, not
  epic→epic"_). Don't scan issue-body prose for "depends on #N" — per **backlog-management**, that
  text is deliberately not there; it lives in the Relationships panel / sub-issues panel instead.
- **There is no phase plan — sequencing is native, full stop.** D-14 used to carry a "Recommended
  build phasing" (Phases 1–6) mirrored as a `Phase N — …` tag in each milestone's `description`;
  both were **retired 2026-09-03** because the milestones are now largely independent and the
  static plan had gone stale. Do **not** look for a phase anywhere. Ordering — within a milestone
  and between milestones alike — comes only from `blocked-by` and sub-issues. A milestone with no
  open `blocked-by` edges into it is runnable now, whatever its number. If you conclude two
  milestones genuinely must be ordered, that belongs in a `blocked-by` between the two specific
  issues that carry the constraint — propose it, don't write it as prose in a description.
- **The shared local cluster already has a lock.** `infra/cluster/with-lock.sh` (flock-based, keyed
  by cluster name so it's shared across every git worktree) serializes any cluster-mutating command
  automatically. There is no need to invent a single "infra owner" agent — every implementer just
  wraps mutating commands with it. See
  [`infra/README.md`](../../../infra/README.md#sharing-the-local-cluster-across-concurrent-sessions).
- **Drive implementation with this repo's own `/orch-*` commands** (`/orch-add-feature`,
  `/orch-change-feature`, `/orch-fix-defect`, `/orch-refine-code`, `/orch-review`), which delegate
  each phase to the project agents: `planner` and `code-architect` to plan, `tdd-guide` to
  implement test-first, `code-reviewer` on every diff, `security-reviewer` when it touches
  auth/input/DB/crypto/secrets, and the specialist reviewer for the paths changed —
  `go-reviewer` (`services/**`), `flutter-reviewer` (`client/**`), `react-reviewer` (`admin/**`),
  `contracts-reviewer` (`contracts/**`), `infra-reviewer` (`infra/**`, `.github/workflows/**`),
  `database-reviewer` (migrations and schema). See
  [`.claude/agents/README.md`](../../agents/README.md) for the full roster.
- **Never invoke ECC's `/epic-*` commands or `/projects`.** They write a custom coordination block
  and `coordination:*` labels into the issue body — exactly the duplication of native fields
  **backlog-management** forbids. "Claiming" an issue here is the native **assignee** field.

## Input

One milestone URL (or `owner/repo` + milestone number). Nothing else — everything below is derived.

## 0. Ingest

```bash
# resolve milestone number from the URL, then pull it + every issue in it
gh api repos/TiagoJVO/beekeepingit/milestones/<n> --jq '{number, title, description}'
gh api "repos/TiagoJVO/beekeepingit/issues?milestone=<n>&state=all" --jq '.[] | {number,title,state,body}'
```

Read, in this order: `CLAUDE.md`, the **requirements-folder** skill's targets (`decisions.md`,
`open-questions.md`, the `FR-*`/`NFR-*` the issues cite), `mandatory-workflow.md`,
`definition-of-done.md`. Confirm which fetched issues are epics (`type/epic` label) vs. leaf
stories/tasks — an epic's own body has no "Stories" checklist; its children are the Sub-issues panel.

## 1. Build the dependency graph — read, don't infer

```bash
# epic -> children
gh api repos/TiagoJVO/beekeepingit/issues/<epic#>/sub_issues --jq '.[] | {number,title,state}'
# story-level blockers
gh api repos/TiagoJVO/beekeepingit/issues/<n>/dependencies/blocked_by --jq '.[] | {number,title,state}'
```

Run `blocked_by` for every issue in the milestone, and follow each blocker out — a blocker may
live in another milestone, which is the only way a cross-milestone constraint is ever expressed.
A milestone `description` says what the milestone _is_; it never says when to build it, so don't
mine it for sequencing:

```bash
gh api repos/TiagoJVO/beekeepingit/milestones --jq '.[] | {number,title,description}'
```

Topologically order the issues from those native edges alone. An issue whose `blocked_by` list is
empty (or fully closed) is runnable now, regardless of milestone number.

**Scope discipline:** default to executing only the milestone you were given. If neighbouring
milestones are also unblocked and could run alongside it, say so once in your Step-2 plan log as an
offer, but don't silently expand scope to other milestones without the user asking — that's a scope
decision, not an implementation detail.

## 2. Stage waves and execute

- Orchestrate as a staged pipeline (the Workflow tool models this well): `parallel()` over each
  wave's issues; don't start wave N+1 until every prerequisite for it is merged **and closed**.
- One implementer agent per issue, each in its own **isolated git worktree**
  (`isolation: 'worktree'`) so parallel agents never collide on uncommitted state.
- Claim = `gh issue edit <n> --add-assignee <actor>` (native field). If the team's Project (v2)
  board tracks a status column, check `gh project item-list` and move the card too — don't invent a
  label for it.
- Each implementer: research (`requirements/` + cited `FR-*`/`D-*`), plan, TDD (`tdd-guide`), review
  (`code-reviewer`, + `security-reviewer` if the diff touches auth/input/DB/crypto/secrets), fix its
  own CRITICAL/HIGH findings, open a PR against the integration branch using
  `.github/PULL_REQUEST_TEMPLATE.md`, referencing the issue and its `FR-*`/`D-*` IDs.

## 3. Shared local cluster

- Any cluster-mutating command (`helm install/upgrade/uninstall`, ad-hoc `kubectl apply`) goes
  through `infra/cluster/with-lock.sh <command>`. `up.sh`/`down.sh` already lock themselves.
  Read-only commands (`kubectl get`, `helm test`/`lint`/`template`) don't need it.
- The lock is keyed by cluster name, not worktree path, so it serializes correctly across parallel
  agents in different worktrees automatically — no designated "infra owner" role needed.
- A schema migration only actually applies once its owning PR is merged to the branch the cluster
  is running; don't apply a migration from an unmerged worktree against the shared cluster.

## 4. Merge policy — autonomous, but bounded

Auto-merge a PR when **all** of `definition-of-done.md` holds: acceptance criteria met, `FR-*`/`D-*`/
issue linked, CI green, tests added, offline/i18n/a11y/tenancy/history/security items addressed,
`requirements/`/`docs/` updated if scope changed, PR template checklist complete. Never force-push,
never bypass hooks or CI, never edit a `D-*`/requirement without the user confirmation
`mandatory-workflow.md` requires.

After merging, close the issue and re-check Section 1's graph — some unblocks are cross-milestone
(a `blocked-by` edge pointing out of this milestone), not just same-epic.

## 5. When to actually stop and ask

Per `mandatory-workflow.md`, stop and surface one batched question (don't interrupt per-issue) only
when:

- A requirement is genuinely missing/ambiguous and guessing would materially change the outcome.
- Correct implementation would require **contradicting** a `D-*`, or an unresolved `Q-*` actually
  blocks the task.
- A `security-reviewer` finding is CRITICAL and the fix needs a product/security tradeoff, not just
  a code fix.
- Two issues/epics conflict in a way `requirements/` can't resolve.
- A migration or infra change is destructive/irreversible.

Everything else — sequencing, file layout, minor technical choices already bounded by existing
decisions, routine merges — proceed without asking.

## 6. Reporting

Keep a running audit trail without blocking on it (issue/PR comments on claim/merge). When the
milestone is fully closed or genuinely blocked, give one final summary: what shipped, what's
pending, and any questions raised along the way.
