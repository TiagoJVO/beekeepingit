# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## Branch `claude/confident-mestorf-9019b3` — #107 history/audit design — before merge

- **What:** on merge, tick #107's acceptance criteria and note the realizing PR (mirrors #105's
  "Realized by PR #113" style); confirm the EPIC-DESIGN board moves #107 to Done.
- **Why:** keep issue↔docs traceability (Definition of Done).
- **Where:** issue #107 · docs: [`docs/architecture/history.md`](docs/architecture/history.md) +
  [`docs/adr/0007-history-audit.md`](docs/adr/0007-history-audit.md); resolves **Q-HIS** (removed
  from [`requirements/open-questions.md`](requirements/open-questions.md)).
- **Status:** pending merge. No code impact — design/HLD only; the build is **EPIC-07 (#8)**.

### Promoted to EPIC-07 (#8) build follow-ups
- In-transaction `audit_log` append on **every** service write **and** the sync-apply path;
  **INSERT-only** DB grant on `audit_log`/`sync_conflict_log`; **append-only + pseudonymity**
  contract tests (NFR-TST); surface `sync_conflict_log` as `superseded` timeline events.
- Retention window / automatic purge / legal-hold + GDPR-erasure runbook → **EPIC-14 (#15)**.
- Global cross-entity audit timeline (outbox → projection) — build only if needed
  ([history.md](docs/architecture/history.md) §5.1).

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
