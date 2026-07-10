# 🐝 BeekeepingIT

Field-management app for beekeepers — manage **apiaries, activities, journeys, and
todos**, with an **offline-first** mobile/tablet client, a **web admin app**, and an
**AI assistant**. Built for a single organization in Portugal first, with
a multi-organization path kept open.

> **Status:** Requirements captured (incl. an **intended** stack/architecture) and a
> **backlog** filed as [GitHub Issues](https://github.com/TiagoJVO/beekeepingit/issues).
> The single-cluster k8s platform + Helm umbrella chart (`infra/`) is built; `services/` has
> landed starting with the `shared` Go library (object storage + DB access abstractions,
> `#85`) and the `servicetemplate` shared service template (health, config, logging, OTel,
> JWT auth, error format, `#20`); `client/` has landed as the Flutter PWA skeleton (`#21`);
> domain services and the walking-skeleton slice are still pending. Source of truth (intent)
> is [requirements/](requirements/); `docs/` documents the system as it's built.

## Intended stack (not final)

Direction we currently intend to take — revisitable, like the requirements: **Flutter**
client (Web/PWA first → Android → iOS) · **Go** services · **React/TS** admin ·
**PostgreSQL + PostGIS** with client offline sync · **Authentik** (OIDC, provider-agnostic) ·
**cloud AI** first.
Reasoning and detail: [requirements/tech-stack.md](requirements/tech-stack.md); the
decisions behind it: [requirements/decisions.md](requirements/decisions.md) (`D-5`…`D-10`).

## Repository layout (monorepo)

```text
beekeepingit/
├── requirements/      # Source of truth: context, FRs, NFRs, decisions, open questions
├── docs/              # Intended architecture, tech stack, ADRs
├── infra/             # k8s cluster bring-up/teardown + Helm umbrella chart (EPIC-13)
├── services/          # Go backend; shared/ = infra library (#85), servicetemplate/ = shared
│                      #   service template (#20) — see services/*/README.md
├── client/            # Flutter PWA — shell, routing, theming, state mgmt, i18n scaffold (#21)
├── .claude/           # AI rules + settings (SessionStart workflow hook)
├── .github/           # Issue templates, PR template, label taxonomy
├── taskfiles/         # Per-language task definitions (go-task)
├── scripts/           # Dev scripts (bootstrap, hooks)
├── mise.toml          # Pinned toolchains + tools
├── Taskfile.yml       # Task runner: lint / format / test / build
├── CLAUDE.md          # Operating manual for AI contributors (start here)
└── CONTRIBUTING.md    # Branching, commits, PR process
```

Code directories (`services/`, `apps/`, `client/`, `infra/`) appear as work needs them
(`D-9`) — nothing is pre-scaffolded.

## Development

One-command bootstrap (Linux / macOS / **WSL2 on Windows**):

```sh
./scripts/bootstrap.sh          # installs mise + toolchains + git hooks
```

Then use the task runner — the same verbs across every language:

```sh
task lint      # lint everything (repo hygiene + each package)
task format    # auto-format
task test      # run tests
task build     # build packages
```

Tooling: **mise** (toolchains) · **go-task** (runner) · **lefthook** (git hooks). Setup,
conventions, and how targets stay green before any code exists:
[docs/development/tooling.md](docs/development/tooling.md) · rationale in
[ADR-0008](docs/adr/0008-monorepo-tooling.md).

## Documentation

| Area                                     | Location                                                                                                                  |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **AI contributor manual**                | [CLAUDE.md](CLAUDE.md)                                                                                                    |
| Contributing (branches/commits/PRs)      | [CONTRIBUTING.md](CONTRIBUTING.md)                                                                                        |
| Dev tooling & conventions (setup, tasks) | [docs/development/tooling.md](docs/development/tooling.md)                                                                |
| Requirements & scope (source of truth)   | [requirements/README.md](requirements/README.md)                                                                          |
| Decisions · open questions               | [requirements/decisions.md](requirements/decisions.md) · [requirements/open-questions.md](requirements/open-questions.md) |
| Backlog (epics, stories, milestones)     | [GitHub Issues](https://github.com/TiagoJVO/beekeepingit/issues) (epics: `type/epic`) · Project board                     |
| Intended stack/architecture              | [requirements/tech-stack.md](requirements/tech-stack.md)                                                                  |
| Built-system docs (as implemented)       | [docs/](docs/)                                                                                                            |

## Project management

Work is tracked on **GitHub** (Issues + Projects):

- **Issues** are filed via the templates in [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE).
- **Labels** are defined in [.github/labels.yml](.github/labels.yml) (apply with a
  label-sync tool or `gh`).
- **Epics/stories** live as [GitHub Issues](https://github.com/TiagoJVO/beekeepingit/issues)
  (epics labelled `type/epic`) — generated from the original Markdown backlog and tracked on
  the Project board.

## Key constraints (see requirements for detail)

- Offline-first field use (gloves-friendly UX); sync when online.
- Full microservices on a single Kubernetes cluster; infra-abstracted & cloud-portable.
- Organization = tenant boundary; RBAC (admin/user); audit history for all entities.
- Cloud AI first (on-device later); English + Portuguese; GDPR.
