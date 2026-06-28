# CLAUDE.md

Entry-point **map** for AI contributors to **BeekeepingIT** (offline-first beekeeping
field app) — so you know where things live and which folders to skip. Operating rules in
`.claude/rules/` are **auto-loaded as memory**; don't import or restate them here.

## Repo map

| Path | What's there (and when to read it) |
|---|---|
| `requirements/` | **Source of truth (intent)** — read when **planning**: context, FRs, NFRs, `decisions.md` (`D-*`), `open-questions.md` (`Q-*`), intended `tech-stack.md` |
| _GitHub Issues_ | The plan/backlog — epics (`type/epic`) & stories, migrated from the retired `planning/` folder. Scope work via `gh issue list` / the Project board |
| `docs/` | Documentation of the system **as built** (+ `adr/`). Near-empty until implementation; read to understand existing behavior |
| `.claude/rules/` | Operating rules — already auto-loaded, no need to open |
| `.github/` | Issue/PR templates, `labels.yml` |
| `CONTRIBUTING.md` | Branching, commits, PR process — read when committing / opening a PR |

### Notes (lifecycle — not derivable from the tree)

- **Backlog lives in GitHub** — the former `planning/` folder was a temporary Markdown
  stand-in; it has been **migrated to GitHub Issues + Projects and retired**. Scope work
  items there (`gh issue list`), not from a repo folder.
- **Nothing is pre-scaffolded** — directories are created as work needs them; the code dirs
  (client / services / infra) appear only once implementation starts.
