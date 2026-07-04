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

## EPIC-13 (#83) — remove the `smoke` placeholder subchart

- **What:** delete `infra/helm/beekeepingit/charts/smoke/`, its `dependencies:` entry in the
  umbrella `Chart.yaml`, and the `smoke:` values keys (`values.yaml` +
  `environments/{staging,prod}.yaml`).
- **Why:** it's a throwaway subchart added only to prove the umbrella↔subchart Helm wiring
  (values overrides, global resource tiers, CI dependency-build/lint/template) end-to-end before
  any real service exists — not a real component.
- **Where:** [`infra/helm/beekeepingit/`](infra/helm/beekeepingit/), documented in its
  [README](infra/helm/beekeepingit/README.md) and
  [`docs/architecture/platform.md`](docs/architecture/platform.md).
- **Status:** pending #84 (Postgres/Keycloak/MinIO/gateway) or #23 (walking-skeleton services) —
  remove it in whichever PR adds the first real service subchart.
