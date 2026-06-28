# CLAUDE.md

Entry-point **map** for AI contributors to **BeekeepingIT** (offline-first beekeeping
field app) — so you know where things live and which folders to skip. Operating rules in
`.claude/rules/` are **auto-loaded as memory**; don't import or restate them here.

## Repo map

| Path | What's there (and when to read it) |
|---|---|
| `requirements/` | **Source of truth (intent)** — read when **planning**: context, FRs, NFRs, `decisions.md` (`D-*`), `open-questions.md` (`Q-*`), intended `tech-stack.md` |
| `planning/` | The plan — `roadmap.md` (milestones / order / deps) + `epics/` (stories → GitHub Issues). **Temporary** (see notes). Read when scoping a work item |
| `docs/` | Documentation of the system **as built** (+ `adr/`). Near-empty until implementation; read to understand existing behavior |
| `.claude/rules/` | Operating rules — already auto-loaded, no need to open |
| `.github/` | Issue/PR templates, `labels.yml` |
| `CONTRIBUTING.md` | Branching, commits, PR process — read when committing / opening a PR |

### Notes (lifecycle — not derivable from the tree)

- **`planning/` is temporary** — a Markdown stand-in for the backlog **until we migrate to
  a GitHub-native flow** (Issues + Projects). Once migrated, it's retired and work lives in
  GitHub.
- **Nothing is pre-scaffolded** — directories are created as work needs them; the code dirs
  (client / services / infra) appear only once implementation starts.
