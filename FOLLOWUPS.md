# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## #106 (branch `claude/focused-chebyshev-df29fb`) — sync & conflict-resolution design

- **What:** docs-only design for #106 — [`docs/architecture/sync.md`](docs/architecture/sync.md) +
  [`docs/adr/0006-sync-conflict-resolution.md`](docs/adr/0006-sync-conflict-resolution.md); resolves
  **Q-SYNC** (removed from `open-questions.md`); D-6/D-12 + FR-OF notes repointed at the docs.
- **Before merge:** open PR referencing #106 (closes it), tick the #106 acceptance criteria, keep
  the PR template checklist honest (docs-only: no code/tests to add here).
- **Promoted (durable → Issues, not this ledger):** build the write-back **coordinator** +
  per-service **sync-apply endpoints**, **notify-and-fix** screens, and the **validation-parity**
  mechanism → **EPIC-06 (#7)**; **history capture** mechanism → **#107**; consolidation → **#110**.
  Deferred refinements (field-level merge, compensation, HLC) are specified in `sync.md` §10 /
  ADR-0006 and gated on the conflict-log telemetry — **do not build pre-emptively**.
- **Status:** design complete; pending PR + review.

## EPIC-13 (platform) — wire API-contract tooling into CI

- **What:** OpenAPI **lint** (Redocly/Spectral), a **breaking-change diff** (`oasdiff`) gate on
  PRs, **server-stub + typed-client codegen** (Go `oapi-codegen`; Dart/TS clients), and
  **contract tests** at service boundaries.
- **Why:** contract-first only holds if CI enforces spec↔code parity and blocks silent `/v1`
  breaks (ADR-0003 / NFR-TST-1). Until then the specs are hand-linted locally.
- **Where:** [`contracts/openapi/`](contracts/openapi/) · design:
  [`docs/architecture/api-contracts.md`](docs/architecture/api-contracts.md) §11 ·
  ADR: [`docs/adr/0003-api-contract-conventions.md`](docs/adr/0003-api-contract-conventions.md)
- **Status:** pending EPIC-13 (#83/#84). Not a blocker for #108 (design/skeletons only).
