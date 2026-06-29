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

## What goes in an entry
Keep each entry actionable and self-contained: **what** is needed, **why**, **where** (file /
issue `#` / PR / `EPIC-*` / requirement ID), and **status**. Group **before-merge** items under
their branch/PR so a reviewer can see what a branch still owes.

## Relationship to the backlog
`FOLLOWUPS.md` is **not** the backlog — GitHub Issues is (see [CLAUDE.md](../../CLAUDE.md)). It is
the **pre-merge checklist + cross-session handoff** for in-flight branches and short-lived notes.
**Promote durable work to a GitHub Issue/epic** and reference it from the entry; prune items once
they merge or move to an issue (git history keeps the record).
