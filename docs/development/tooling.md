# Development tooling & conventions

How to set up and run the monorepo. The _why_ is in
[ADR-0008](../adr/0008-monorepo-tooling.md); this is the practical reference.

**Stack:** [mise](https://mise.jdx.dev) (toolchains + bootstrap) · [go-task](https://taskfile.dev)
(task runner) · [lefthook](https://lefthook.dev) (git hooks). Assumes a POSIX shell — Linux,
macOS, or **WSL2 on Windows**.

## Bootstrap (one command)

```sh
./scripts/bootstrap.sh
```

This installs mise (if missing), then every pinned toolchain/tool from
[`mise.toml`](../../mise.toml), then the git hooks. After it finishes, activate mise in your
shell so tools are on `PATH` in new terminals:

```sh
echo 'eval "$(mise activate bash)"' >> ~/.bashrc   # or zsh
```

Then the `task` command is available directly (otherwise prefix with `mise exec --`).

## Everyday commands

| Command       | What it does                                            |
| ------------- | ------------------------------------------------------- |
| `task`        | List all tasks                                          |
| `task lint`   | Lint everything — repo hygiene + every language package |
| `task format` | Auto-format everything (writes changes)                 |
| `task test`   | Run all tests                                           |
| `task build`  | Build all packages                                      |
| `task ci`     | What CI runs — format is clean **and** everything lints |
| `task setup`  | (Re)install git hooks                                   |

Language-scoped variants exist too: `task go:lint`, `task web:test`, `task dart:format`,
`task repo:markdown`, etc. Run `task --list` for the full set.

### Why targets pass with no code yet

Per [D-9](../../requirements/decisions.md), packages are created as work needs them. The `go:` /
`web:` / `dart:` targets **discover** their packages (`go.mod` / `package.json` / `pubspec.yaml`)
and **no-op** with a message when none exist. The `repo:` hygiene targets (Prettier, Markdown,
actionlint, shellcheck, gitleaks) run today, so `task lint` is meaningful from day one.

## Adding a package

- **Go service** → add `services/<name>/go.mod`. It's picked up automatically and inherits
  [`.golangci.yml`](../../.golangci.yml).
- **Web app** → add `apps/<name>/package.json` exposing `lint` / `format` / `test` / `build`
  scripts; the root fans out to them. Keep the package's own eslint/prettier config local.
- **Flutter client** → add the package's `pubspec.yaml`, add `flutter`/`dart` to
  [`mise.toml`](../../mise.toml), and `include:` the shared
  [`analysis_options.yaml`](../../analysis_options.yaml) plus `flutter_lints` in the package.

## Git hooks

Installed by bootstrap (or `task setup`). On commit:

- **pre-commit** — formats staged files (Prettier / gofmt / dart format, re-staged) and runs fast
  gates that **block** on failure: markdownlint, actionlint, shellcheck, and gitleaks (staged
  secret scan).
- **commit-msg** — enforces [Conventional Commits](../../CONTRIBUTING.md#commits--conventional-commits)
  via [`scripts/check-commit-msg.sh`](../../scripts/check-commit-msg.sh).

Bypass in an emergency with `git commit --no-verify` (CI still enforces the same checks).

## Linter/formatter configs

| Language / area  | Config                                                           | Tool              |
| ---------------- | ---------------------------------------------------------------- | ----------------- |
| Go               | [`.golangci.yml`](../../.golangci.yml)                           | golangci-lint     |
| Dart/Flutter     | [`analysis_options.yaml`](../../analysis_options.yaml)           | dart analyze      |
| Markdown         | [`.markdownlint-cli2.yaml`](../../.markdownlint-cli2.yaml)       | markdownlint-cli2 |
| MD/YAML/JSON fmt | [`.prettierrc.yaml`](../../.prettierrc.yaml) + `.prettierignore` | prettier          |
| GitHub Actions   | —                                                                | actionlint        |
| Secrets          | —                                                                | gitleaks          |

Note: `.prettierignore` excludes `infra/helm/**/templates/**` — Helm chart templates embed Go
template syntax (`{{ .Values.x }}`) inside `.yaml` files, which is not valid standalone YAML and
a generic formatter would corrupt. Those files are linted/rendered by `helm lint`/`helm template`
in [`helm-ci.yml`](../../.github/workflows/helm-ci.yml) instead, not by `task lint`.

## Infra toolchain

[`infra/`](../../infra/) (the single-cluster k8s platform, [ADR — platform.md](../architecture/platform.md))
needs `k3d`, `kubectl`, and `helm` on `PATH`; these are pinned in [`mise.toml`](../../mise.toml)
(`helm` matches the version pinned in `helm-ci.yml`) and installed by the same bootstrap.

## CI

The [`ci`](../../.github/workflows/ci.yml) workflow runs `task ci` (lint + test) on every PR
via `mise-action`. It does **not** cover Helm charts — those have their own path-filtered
[`helm-ci.yml`](../../.github/workflows/helm-ci.yml), triggered only when `infra/helm/**` changes.
Per-language, path-filtered build/test matrices and the OpenAPI/contract tooling land in
**EPIC-13** (see [FOLLOWUPS.md](../../FOLLOWUPS.md)).
