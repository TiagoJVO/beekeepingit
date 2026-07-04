# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## Tooling — deferred (post-#19)

- **golangci-lint v1 → v2** config migration (v2 is current; `.golangci.yml` uses v1 schema).
- **Add `flutter`/`dart` to [`mise.toml`](mise.toml)** when the Flutter client package lands (D-10);
  wire `dart:build` and have the client `include:` the shared `analysis_options.yaml` +
  `flutter_lints`.
- **Pinned-tool updates** — Dependabot covers GitHub Actions only; add a mechanism (renovate/mise)
  to bump `mise.toml` pins.

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

## #86 (GitOps/Flux) — before-merge: one-time cluster bootstrap

- **What:** after this merges to `main`, run the one-time bootstrap on the dev cluster:
  `kubectl apply -f infra/gitops/clusters/dev/` (documented in
  [`infra/gitops/README.md`](infra/gitops/README.md)). Nothing deploys via Flux until this runs,
  since the `GitRepository` tracks `main` and the manifests don't exist there yet.
- **Why:** deliberate — bootstrapping isn't done via `flux bootstrap` (would push straight to
  `main`, bypassing PR review; see `D-13`/ADR-0009), so it needs this one manual step post-merge.
- **Where:** [`infra/gitops/`](infra/gitops/).
- **Status:** before-merge for this branch. All 5 acceptance criteria (reconcile/deploy,
  drift-revert, sync-on-merge, sync/health observability, rollback) were live-verified against
  the real `k3d-beekeeping` cluster during implementation, pointed at this feature branch — see
  the branch history for the `reconcileStrategy: Revision` fix this verification caught (the
  default strategy only re-deploys on a `Chart.yaml` version bump, which would've silently
  broken "merge auto-deploys" for ordinary values/template edits).
