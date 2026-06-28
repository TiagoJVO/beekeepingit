# 🐝 BeekeepingIT

Field-management app for beekeepers — manage **apiaries, activities, journeys, and
todos**, with an **offline-first** mobile/tablet client, a **web admin app**, and an
**AI assistant**. Built for a single organization in Portugal first, with
a multi-organization path kept open.

> **Status:** Requirements captured (incl. an **intended** stack/architecture) and a
> **backlog** filed as [GitHub Issues](https://github.com/TiagoJVO/beekeepingit/issues). **Nothing is built
> yet** — the source of truth (intent) is [requirements/](requirements/); `docs/` will
> document the system as it's built.

## Intended stack (not final)

Direction we currently intend to take — revisitable, like the requirements: **Flutter**
client (Web/PWA first → Android → iOS) · **Go** services · **React/TS** admin ·
**PostgreSQL + PostGIS** with client offline sync · **Keycloak** · **cloud AI** first.
Reasoning and detail: [requirements/tech-stack.md](requirements/tech-stack.md); the
decisions behind it: [requirements/decisions.md](requirements/decisions.md) (`D-5`…`D-10`).

## Repository layout (monorepo)

```
beekeepingit/
├── requirements/      # Source of truth: context, FRs, NFRs, decisions, open questions
├── docs/              # Intended architecture, tech stack, ADRs
├── .claude/           # AI rules + settings (SessionStart workflow hook)
├── .github/           # Issue templates, PR template, label taxonomy
├── CLAUDE.md          # Operating manual for AI contributors (start here)
└── CONTRIBUTING.md    # Branching, commits, PR process
```

## Documentation

| Area | Location |
|---|---|
| **AI contributor manual** | [CLAUDE.md](CLAUDE.md) |
| Contributing (branches/commits/PRs) | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Requirements & scope (source of truth) | [requirements/README.md](requirements/README.md) |
| Decisions · open questions | [requirements/decisions.md](requirements/decisions.md) · [requirements/open-questions.md](requirements/open-questions.md) |
| Backlog (epics, stories, milestones) | [GitHub Issues](https://github.com/TiagoJVO/beekeepingit/issues) (epics: `type/epic`) · Project board |
| Intended stack/architecture | [requirements/tech-stack.md](requirements/tech-stack.md) |
| Built-system docs (as implemented) | [docs/](docs/) |

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
