# Contributing to BeekeepingIT

Thanks for contributing! This is a small project — the goal is a clean history and
small, reviewable changes. Keep it simple.

> Most work is implemented by Claude. When **planning** a task, follow the workflow in
> [CLAUDE.md](CLAUDE.md) and read the sources of truth in [requirements/](requirements/).

## Getting set up

One-command bootstrap (Linux / macOS / **WSL2 on Windows**):

```sh
./scripts/bootstrap.sh   # installs mise + toolchains + git hooks (lefthook)
```

Then run everything through the task runner — `task lint`, `task format`, `task test`,
`task build`. Git hooks format staged files and block on lint/secret failures. Full details:
[docs/development/tooling.md](docs/development/tooling.md) · rationale:
[ADR-0008](docs/adr/0008-monorepo-tooling.md).

## Workflow (GitHub Flow)

1. Create a short-lived branch off `main` for **one** task.
2. Make small, focused commits.
3. Open a pull request early; keep it small.
4. Ensure CI passes; address review.
5. Squash-merge to `main`; delete the branch.

Keep `main` always releasable.

## Branch naming

`<type>/<short-description>` (lowercase, hyphenated), optionally with an issue or epic ref:

```text
feat/EPIC-02-apiary-crud
fix/sync-conflict-tombstone
docs/update-roadmap
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`, `ci`, `build`.

## Commits — Conventional Commits

Format: `type(scope): short description`

```text
feat(apiaries): add CRUD (FR-AP-1, #123)
fix(sync): resolve delete tombstone race (Q-SYNC)
docs(requirements): clarify journey stats (FR-JO-1)
```

- Same `type` set as branches. The **type reflects the outcome** (a refactor that fixes a
  bug is a `fix`). The `commit-msg` hook enforces this format locally; PR titles are checked
  in CI.
- **Scope** = the area touched; keep scopes consistent (e.g. always `auth`, not sometimes
  `authentication`).
- Be specific: "fix race in webhook retry", not "fix bug".
- Breaking changes: add a `BREAKING CHANGE:` footer.
- Reference IDs where useful: `FR-*/NFR-*`, `D-*`, `Q-*`, `EPIC-*`, issue `#`.

## Pull requests

- Fill in [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md); use
  `Closes #<issue>`.
- One logical change per PR. Link the requirement IDs and epic/issue it implements.
- Include tests for the change; update docs when behavior or scope changes.
- If the change adds/removes a route, table, or top-level dependency, re-run
  `/ecc:update-codemaps` and include the updated [docs/CODEMAPS/](docs/CODEMAPS/) files in
  the same PR — otherwise the maps silently drift from the as-built system.
- Meet the [Definition of Done](.claude/rules/definition-of-done.md).

## Tests

Add or update tests with every change, and make sure they pass in CI before requesting
review. (Project-wide testing expectations live in
[.claude/rules/coding-standards.md](.claude/rules/coding-standards.md).)

## Proposing changes to scope, decisions, or architecture

Requirements and decisions are the working default but **not immutable**. If a change
makes sense, say so in the issue/PR, get confirmation, and update the relevant file
(`requirements/`, `requirements/decisions.md`) in the same change — don't silently
diverge. Architecture changes are made during implementation (see [CLAUDE.md](CLAUDE.md)).
