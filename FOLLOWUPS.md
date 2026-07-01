# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## SP-1 sync-engine spike (#54) — branch `claude/vigilant-napier-b1e0c8`

- **What landed:** engine pick **PowerSync** (self-hosted Open Edition), resolved by a head-to-head
  **and a working k8s prototype** (create → offline edit → sync + server-authoritative LWW/conflict-log,
  **8/8** automated checks). Recorded in [ADR-0005](docs/adr/0005-sync-engine-choice.md) +
  [SP-1 report](docs/spikes/sp-1-powersync-vs-electricsql.md); `D-6`, `Q-SYNC`, `tech-stack.md` updated.
- **Before merge:** commit + open the PR for the above; confirm **#54 closed** with a link to ADR-0005.
- **Prototype NOT committed** (research only, per #54's AC): the throwaway kind + Postgres + PowerSync +
  `@powersync/web` PWA stack ran in the session scratchpad and was torn down — reproduction lives in
  the SP-1 report. (Local WSL `.wslconfig` `vmIdleTimeout=-1` was added for the spike; remove if unwanted.)
- **Handoff → #106 (EPIC-06 #7):** cross-service write-back **atomicity mechanism** (D-12), **org-scoped
  Sync Rules** (the client slice), tombstones/deletes, client↔server validation parity, and the
  "synced"/notify-and-fix UX; **validate iOS PWA** storage durability when iOS is in scope (D-10).

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
