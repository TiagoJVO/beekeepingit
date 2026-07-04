# 0008 — Monorepo tooling & conventions (mise + Taskfile + lefthook)

- **Status:** Accepted
- **Date:** 2026-07-04
- **Issue / Epic:** #19 · **Milestone:** M0
- **Requirements:** [NFR-MNT-1](../../requirements/non-functional-requirements.md),
  [NFR-TST-1](../../requirements/non-functional-requirements.md)
- **Decisions:** [D-9](../../requirements/decisions.md) (monorepo), [D-10](../../requirements/decisions.md)
  (PWA → Android → iOS rollout), [D-5](../../requirements/decisions.md) (Go / Flutter / React stack)
- **As-built reference:** [docs/development/tooling.md](../development/tooling.md)

## Context

[D-9](../../requirements/decisions.md) puts everything in one monorepo (client, Go services,
admin app, infra, docs) and mandates **"directories are created as work needs them, not
pre-scaffolded."** The stack ([D-5](../../requirements/decisions.md)) is polyglot — Go, Dart/Flutter,
TypeScript/React — so contributors need **one consistent way** to lint, format, test and build
across languages, an enforced set of conventions (NFR-MNT-1), and a foundation for automated
testing/CI (NFR-TST-1, and the contract tooling deferred to EPIC-13).

The catch: at M0 **no code packages exist yet** (no `go.mod`, `package.json`, `pubspec.yaml`), so
the tooling must add value and stay green _before_ there is any code to lint — then extend
seamlessly as packages land. It also must be reproducible across the WSL2/Linux/macOS machines
the team uses (Windows contributors work under WSL2).

## Decision

Adopt three composable, single-binary tools plus per-language linter configs:

1. **Toolchain management + bootstrap — [mise](https://mise.jdx.dev)** (`mise.toml`). Pins every
   language toolchain (Go, Node) and every tool (task, lefthook, golangci-lint, actionlint,
   shellcheck, gitleaks, prettier, markdownlint) at explicit versions, plus the `infra/` ops
   toolchain (`helm` — pinned to match `helm-ci.yml`, `kubectl`, `k3d`) once EPIC-13 #83 landed
   the k8s platform and made those a real prerequisite. **One bootstrap command** —
   `./scripts/bootstrap.sh` — installs mise, runs `mise install`, and installs git hooks. The
   file **grows as packages land** (e.g. `flutter` is added with the client), honoring D-9.

2. **Task runner — [go-task](https://taskfile.dev)** (`Taskfile.yml` + `taskfiles/*.yml`). Exposes
   the same four verbs everywhere — **`lint` / `format` / `test` / `build`** — plus `bootstrap`,
   `setup`, `ci`. Aggregate targets fan out to per-language taskfiles that **discover packages**
   (`go.mod` / `package.json` / `pubspec.yaml`) and **no-op gracefully** when none exist. A
   `repo:` namespace runs cross-cutting hygiene (Prettier, Markdown, actionlint, shellcheck,
   gitleaks) that is useful from day one.

3. **Git hooks — [lefthook](https://lefthook.dev)** (`lefthook.yml`). `pre-commit` auto-formats
   staged files (re-staged) and runs fast lint/secret gates that **block** on failure;
   `commit-msg` enforces Conventional Commits locally (mirrored on PR title in CI). Uses
   `glob_matcher: doublestar` so a pattern like `**/*.go` matches at **any** depth including the
   repo root — lefthook's default matcher requires `**` to descend at least one directory, which
   would otherwise silently skip root-level files.

4. **Per-language linter/formatter configs** at the repo root as the shared baseline every
   package inherits: `.golangci.yml` (Go), `analysis_options.yaml` (Dart), `.prettierrc.yaml` +
   `.prettierignore` and `.markdownlint-cli2.yaml` (repo docs/config). TS/React packages carry
   their own eslint/prettier config and expose `lint`/`format` scripts the root fans out to.
   `.prettierignore` excludes `infra/helm/**/templates/**`: Helm templates embed Go template
   syntax inside `.yaml`, which isn't valid standalone YAML and a generic formatter would corrupt
   — that content is linted/rendered by `helm lint`/`helm template` in `helm-ci.yml` instead.
   `.markdownlint-cli2.yaml` disables `MD036` (every ADR's `## Consequences` section uses bold
   **Positive**/**Negative** sub-labels by deliberate convention, not as a heading substitute) and
   `MD018` (hand-wrapped prose can start a line with an inline `#123` issue reference, which looks
   like a malformed ATX heading but isn't).

5. **CI** — a `lint` workflow runs `task ci` via `mise-action`, enforcing the same checks on every
   PR. Per-language, path-filtered build/test matrices are **out of scope here** and land in
   EPIC-13 alongside the OpenAPI/contract tooling. _(Renamed `lint` → `ci` with #85 once `task ci`
   started running tests too — see `docs/adr/0011-infra-abstraction-object-storage-db-access.md`.)_

## Consequences

**Positive**

- **One surface, every language** (`task lint|format|test|build`) — directly serves NFR-MNT-1 and
  gives NFR-TST-1 a home to grow into. Contributors and CI run identical commands.
- **Green before code exists:** graceful no-op discovery means the framework lands at M0 without
  pre-scaffolding packages (honors D-9), while repo-hygiene checks add immediate value.
- **Reproducible, one-command onboarding:** pinned versions in `mise.toml` + `bootstrap.sh` remove
  "works on my machine" drift; single-binary tools (no Python/Node runtime prerequisite for the
  hook manager or task runner) keep setup light and cross-platform (WSL2/Linux/macOS).
- **Extends cleanly:** EPIC-13 bolts OpenAPI lint / `oasdiff` / codegen / contract tests onto these
  same `task` targets and CI; new services just add a `go.mod` and are picked up automatically.

**Negative / risks**

- **POSIX shell assumption:** the discovery scripts use `find`/`sh`, so native Windows `cmd`/
  PowerShell is unsupported — contributors use WSL2 (already the team's environment). Documented.
- ~~**golangci-lint pinned to v1**~~ **Superseded:** migrated to v2 with #85 — landing
  `services/shared`'s real dependencies pulled in transitive `golang.org/x/*` requiring Go
  1.25+, which v1's last release (built with go1.24.1) can't lint. See
  [ADR-0011](0011-infra-abstraction-object-storage-db-access.md#golangci-lint-v1-v2-unplanned-but-forced-by-this-task).
- **Version pins need periodic bumps** (Dependabot covers Actions, not mise yet) — tracked as a
  follow-up.
- **First run must normalize existing docs** to be Prettier/Markdown-clean (`task format`), a
  one-time cost captured in [FOLLOWUPS.md](../../FOLLOWUPS.md).

## Alternatives considered

- **GNU Make** as the task runner: universal on Linux, zero-install there, but clunky for
  conditional per-package discovery and poor on Windows. **Rejected** — go-task's YAML + built-in
  cross-platform shell is a better fit for a polyglot monorepo. `just` is nicer than Make but adds
  another niche toolchain with a smaller ecosystem.
- **pre-commit (Python framework)** for hooks: the de-facto standard with a huge hook ecosystem,
  but forces a Python runtime on every contributor. **Rejected** in favor of the single Go binary
  lefthook. **husky + lint-staged** was rejected for pulling Node/npm into the root before the
  admin app exists.
- **asdf / plain bootstrap.sh** instead of mise: asdf is mature but slower (shell) and needs
  per-language plugins; a hand-rolled script gives no version pinning and drifts. **Rejected** —
  mise is a fast single binary with the same one-file model and reproducible pins.
- **Turborepo / Nx:** powerful task graphs + caching, but JS-ecosystem-centric and heavyweight for
  a Go-led backend; caching value is low until the build graph is large. **Rejected** for now.

## Follow-ups

- **EPIC-13** — per-language path-filtered CI matrices + OpenAPI lint / `oasdiff` / codegen /
  contract tests, layered on these `task` targets (tracked in [FOLLOWUPS.md](../../FOLLOWUPS.md)).
- **#83 landed first** (single-cluster k8s platform + Helm umbrella chart, merged ahead of this
  ADR) — reconciled here: `helm`/`kubectl`/`k3d` added to `mise.toml`, `infra/helm/**/templates/**`
  excluded from Prettier, and the repo-wide shellcheck task widened to cover `infra/cluster/*.sh`
  (previously scanned `scripts/` only).
- **When the Flutter client lands (D-10)** — add `flutter`/`dart` to `mise.toml`; the client's
  `analysis_options.yaml` includes this baseline + `flutter_lints`.
- ~~**golangci-lint v1 → v2** config migration.~~ **Done** — see #85 / ADR-0011.
- Consider a mise/Dependabot equivalent for pinned-tool updates.
