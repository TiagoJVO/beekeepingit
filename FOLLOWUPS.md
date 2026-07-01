# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

<!-- Closed for PR #123 (SP-1 sync-engine spike, #54): engine pick → PowerSync (self-hosted Open
Edition), recorded in ADR-0005 + docs/spikes/sp-1-powersync-vs-electricsql.md; D-6 / Q-SYNC /
tech-stack updated; #54 closed on merge. Handoff → #106: cross-service write-back atomicity (D-12),
org-scoped Sync Rules, tombstones/deletes, client↔server validation parity, notify-and-fix UX, iOS
PWA storage durability. Prototype not committed (research only). Local WSL `.wslconfig`
`vmIdleTimeout=-1` left in place; remove if unwanted. -->

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

<!-- Closed for PR #112 (docs/epic-design-service-decomposition): AI write-actions story → #114
(EPIC-08); sync write-back D-12 (scope + failure UX + atomicity mechanism) → #106 (+ EPIC-06 #7);
ai-schema consistency → PR #113 comment; ADR-0002 → tracked in #114. -->
