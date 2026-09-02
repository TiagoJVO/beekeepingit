# Project agents

Subagents Claude Code delegates to — one `*.md` each (frontmatter + operating prompt). Vendored from [ECC](https://github.com/affaan-m/ECC) at `754b8dd` and adapted: substance preserved, only what this repo needs changed. Three standing adaptations apply to all of them, listed under the table.

| Agent                 | Purpose                                                                       |
| --------------------- | ----------------------------------------------------------------------------- |
| `planner`             | Turns an issue + `requirements/` into a phased, traceable implementation plan |
| `code-architect`      | Designs a feature's architecture and build order against existing patterns    |
| `code-explorer`       | Traces how an existing feature works — entry points, flow, layers, deps       |
| `tdd-guide`           | Enforces the red/green/refactor loop with a verified RED gate                 |
| `code-reviewer`       | General quality/security review of a diff; routes to the specialists below    |
| `security-reviewer`   | Secrets, OWASP Top 10, tenancy escapes, AI-consent and AI-write-safety        |
| `go-reviewer`         | Idiomatic Go, error handling, concurrency — `services/`                       |
| `go-build-resolver`   | Minimal fixes for Go build, vet, and golangci-lint failures                   |
| `flutter-reviewer`    | Dart/Flutter idioms, widgets, state, offline, a11y — `client/`                |
| `dart-build-resolver` | Minimal fixes for `dart analyze` / Flutter build / pub failures               |
| `database-reviewer`   | Postgres/PostGIS schema, migrations, sqlc queries, indexes                    |
| `react-reviewer`      | React + strict TypeScript for the online-only `admin/` app                    |
| `contracts-reviewer`  | OpenAPI conventions, breaking changes, sync validation parity — `contracts/`  |
| `infra-reviewer`      | Helm chart, Flux/GitOps, and cluster manifest review — `infra/`               |

1. **Task targets** — everything runs through go-task (`task lint`/`test`/`build`, `task go:*`, `dart:*`, `web:*`, `openapi:*`, `repo:*`), never a raw `npm test`, `golangci-lint`, or `tsc`.
2. **CI-green bar** — done means tests added/updated and green via `task test`, then CI green; this repo has no coverage percentage.
3. **Repo invariants** — contract-first, `organization_id` tenancy, history (`FR-HIS`), offline/sync parity, EN/PT strings, WCAG 2.2 AA — per the Definition of Done in `.github/PULL_REQUEST_TEMPLATE.md`.
