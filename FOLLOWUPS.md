# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## Branch `docs/epic-design-service-decomposition` — PR #112 (#104)

### Before merge
- [ ] **Coordinate sibling PR #113 (#105, data model).** Its `ai` schema is defined as
      "consent records / query logs" — update it to add **action logs** and the
      **no-direct-write** note so it agrees with the AI write-safety guarantee (D-11).
      File: the #105 data-model doc on branch `docs/epic-design-data-model`.
- [ ] **Reflect the sync write-back decision (D-12) in the backlog.** Update **EPIC-06
      (Offline & Sync)** and the **#106** sync-design task with: atomic per-push write-back
      (rollback on partial failure), client↔server **validation parity**, and the
      **notify-and-fix** failure flow. Check whether milestones / sub-tasks shift.

### Deferred (not blocking this PR)
- [ ] **EPIC-08 (AI Assistant): add an "AI write-actions" story** — NL→action, user-confirmation
      UX, mediated execution via domain APIs. New deps: **#108** (write contracts), **#107**
      (history). Optional separate **voice / STT spike** (D-11 defers voice here).
- [ ] **Design the sync-failure UX** (notify pushing user → fix on client → re-push) — part of
      **#106 / EPIC-06** (FR-OF-2, D-12). The flow is currently undefined.
- [ ] **Resolve the write-back atomicity mechanism** across per-service writes —
      saga/compensation vs a per-service transactional batch + coordinator (tension with
      ownership rule 1) — **#106 + SP-1** (Q-SYNC, D-12).
- [ ] **Write ADR-0002 "AI write-actions model"** when EPIC-08 design starts. The decision lives
      in D-11 for now; ADR-0001 carries only the corrected `ai` boundary rule.
