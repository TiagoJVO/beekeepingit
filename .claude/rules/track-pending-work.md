# Rule: Track pending work in the repo

Work a session **identifies but does not finish** — before-merge follow-ups, deferred
cleanups, backlog/issue/milestone updates still owed, "do this when `EPIC-*` starts" notes —
must not live only in chat. **Persist it to [`FOLLOWUPS.md`](../../FOLLOWUPS.md) and commit it**,
so progress and continuity are tracked in version control and survive across sessions.

## When

- Before ending a session/task that leaves anything pending, **record it** in `FOLLOWUPS.md`
  and include that file in the commit.
- When you **complete** a tracked item, tick or remove it **in the same change that lands the
  work**, so the ledger never drifts from reality.
- **Any time you touch this file, sweep the whole thing, not just your own new entries.** For
  every existing entry, check whether the issue/epic/PR it's blocked on or scoped to has since
  closed or merged (`gh issue view <n>` / `gh pr view <n>`). If it has, that entry is now stale
  by definition and must be resolved in the same change: prune it if the work is actually done
  (git history at the closing commit keeps the record — don't re-describe a shipped fix here),
  or promote it to a GitHub Issue/fold it into an existing one's scope and prune it here once
  referenced. Don't leave a stale "pending EPIC-X" status sitting once EPIC-X has closed — that's
  exactly how this file silently turns into a second backlog instead of a live ledger.

## What goes in an entry

Keep each entry actionable and self-contained: **what** is needed, **why**, **where** (file /
issue `#` / PR / `EPIC-*` / requirement ID), and **status**. Group **before-merge** items under
their branch/PR so a reviewer can see what a branch still owes.

## Relationship to the backlog

`FOLLOWUPS.md` is **not** the backlog — GitHub Issues is (see [CLAUDE.md](../../CLAUDE.md)). It is
the **pre-merge checklist + cross-session handoff** for in-flight branches and short-lived notes.
**Promote durable work to a GitHub Issue/epic** and reference it from the entry; prune items once
they merge or move to an issue (git history keeps the record).

This file should trend toward **empty**, not grow monotonically. A before-merge entry belongs to
the PR that added it and must be resolved — pruned or promoted — by the time that specific PR
merges; it does not get to ride along as a permanent fixture once its own PR has landed. If you
find an entry whose owning PR/issue already merged or closed, that's not "history worth keeping,"
it's a leftover that should have been cleared already (see the sweep step above).
