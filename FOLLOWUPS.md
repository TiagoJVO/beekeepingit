# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.

## Branch `claude/zealous-clarke-5e57d6` (#19) — before merge

- [x] **Ran the full toolchain end-to-end in WSL2 (Ubuntu) — `task lint` and `task ci` are both
      green.** `./scripts/bootstrap.sh` → `task format` (normalized 40 pre-existing
      Markdown/YAML/JSON files to Prettier, included in this diff) → `task lint` → `task ci`.
      Found and fixed along the way:
  - **`mise trust` was missing from `bootstrap.sh`** — mise refuses to read `mise.toml` until
    the config is explicitly trusted; every fresh clone would have hit this. Added the step.
  - **41 markdownlint findings** in pre-existing docs: fixed the mechanical ones (missing
    fenced-code-block languages, 2 bare URLs in the SP-1 spike, two `#` headings in
    `requirements/decisions.md` that should have been `##`); disabled `MD036`
    (bold-as-heading — every ADR's `## Consequences` deliberately uses **Positive**/**Negative**
    this way) and `MD018` (false-positives on hand-wrapped prose starting a line with an inline
    `#123` issue ref) in `.markdownlint-cli2.yaml`.
  - A `shellcheck` info-level finding on the intentionally-unexpanded `$(...)` in
    `bootstrap.sh`'s printed copy-paste example — added a `shellcheck disable=SC2016` directive
    (on its own line; a trailing inline explanation breaks shellcheck's directive parser).
  - Confirmed `lefthook install` **does** work correctly from inside this git worktree — hooks
    install into the shared common `.git/hooks/` (not per-worktree), which is normal git
    worktree behavior, not a special case needing a workaround.
  - Confirmed the mise-installed `helm 3.21.2` renders/lints the umbrella chart cleanly
    (`helm lint` inside `infra/helm/beekeepingit/`), and that `infra/helm/**/templates/**` was
    correctly left untouched by `task format` (Go-template YAML preserved).
- [x] **Version pins in [`mise.toml`](mise.toml) resolve** — verified via `mise install`:
      `go 1.24.13`, `node 22.23.1`, `task 3.52.0`, `lefthook 1.13.6`, `golangci-lint 1.64.8`,
      `actionlint 1.7.12`, `shellcheck 0.11.0`, `gitleaks 8.30.1`, `helm 3.21.2`, `kubectl 1.36.2`,
      `k3d 5.9.0`, `npm:prettier 3.9.4`, `npm:markdownlint-cli2 0.23.0`.
- [x] **Rebased onto `main` after #83 merged** (single-cluster k8s platform + Helm umbrella
      chart, PR #129) — reconciled: added `helm`/`kubectl`/`k3d` to `mise.toml`; excluded
      `infra/helm/**/templates/**` from Prettier (Go-template YAML, not valid standalone YAML);
      widened the shellcheck task from `scripts/` to repo-wide so it covers `infra/cluster/*.sh`;
      also fixed a pre-existing bug where every `lefthook.yml` glob (`*.go`, `*.dart`, etc.) only
      matched **root-level** files under lefthook's default matcher — switched to
      `glob_matcher: doublestar` so `**/*.ext` matches at any depth, matching normal expectations.
- [ ] Not yet committed — awaiting go-ahead to commit and open the PR.

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
