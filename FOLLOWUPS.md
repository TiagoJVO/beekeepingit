# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

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

## Backlog notes owed by the design work (#110 / FR-OF-3)

- **What:** short pointer notes on the issues the designs re-scoped or de-risked:
  - **#23** — link `docs/architecture/walking-skeleton.md` (§7.2 is its build list, §7.3 its
    test spec); refresh the stale "sync engine choice via SP-1" note (resolved → PowerSync).
  - **#24** — the skeleton (#23) ships the **dev-grade** realm import + PWA login wiring
    (walking-skeleton §7.2 item 1); #24 hardens/productionizes — don't build it twice.
  - **#28** — the membership read path is now **decided**: internal REST resolve calls +
    short-TTL cache (walking-skeleton §4.2); #28 implements, not re-decides.
  - **#31** *(optional)* — REST write handlers land there; the PWA never calls them
    (single local-first write path, walking-skeleton §4.4).
  - **EPIC-06 #55/#58** — the **connection-quality sync gate** (FR-OF-3; mechanism
    `docs/architecture/sync.md` §7.1) is part of the client sync integration / offline UX.
- **Why:** the decisions live in `docs/`; whoever picks up these issues should find the
  pointer on the issue itself instead of rediscovering it.
- **Where:** PR #127 (walking-skeleton design) · the FR-OF-3 PR (sync quality gate).
- **Status:** proposed 2026-07-04, awaiting user go-ahead to edit the issue bodies.
