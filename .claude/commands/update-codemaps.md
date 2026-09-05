---
description: Scan project structure and generate token-lean architecture codemaps.
---

<!-- Vendored from ECC (affaan-m/ECC@754b8dd) and adapted for BeekeepingIT -->

# Update Codemaps

Analyze the codebase structure and generate token-lean architecture documentation.

## Step 1: Scan Project Structure

1. Identify the project type (monorepo, single app, library, microservice)
2. Find all source directories (`services/`, `client/`, `admin/`, `contracts/`, `infra/`)
3. Map entry points (`main.go`, `main.dart`, `main.tsx`, `Chart.yaml`, …)

## Step 2: Generate Codemaps

Create or update codemaps in `docs/CODEMAPS/`:

| File              | Contents                                                      |
| ----------------- | ------------------------------------------------------------- |
| `architecture.md` | High-level system diagram, service boundaries, data flow      |
| `backend.md`      | API routes, middleware chain, service → repository mapping    |
| `frontend.md`     | Page tree, component hierarchy, state management flow         |
| `data.md`         | Database tables, relationships, migration history             |
| `dependencies.md` | External services, third-party integrations, shared libraries |

### Codemap Format

Each codemap should be token-lean — optimized for AI context consumption:

```markdown
# Backend Architecture

## Routes

POST /api/users → UserController.create → UserService.create → UserRepo.insert
GET /api/users/:id → UserController.get → UserService.findById → UserRepo.findById

## Key Files

src/services/user.ts (business logic, 120 lines)
src/repos/user.ts (database access, 80 lines)

## Dependencies

- PostgreSQL (primary data store)
- Redis (session cache, rate limiting)
- Stripe (payment processing)
```

## Step 3: Diff Detection

1. If previous codemaps exist, calculate the diff percentage
2. If changes > 30%, show the diff and request user approval before overwriting
3. If changes <= 30%, update in place

## Step 4: Add Metadata

Add a freshness header to each codemap:

```markdown
<!-- Generated: 2026-02-11 | Files scanned: 142 | Token estimate: ~800 -->
```

## Step 5: Report the Diff Summary

ECC writes this summary to `.reports/codemap-diff.txt`. **Do not do that here** — `.reports/` is
gitignored in this repo, so a summary written there is invisible to reviewers and lost on a clean
checkout. Put the summary in the **PR description** instead (under Summary, or Before merge if it
raises follow-up work):

- Files added/removed/modified since the last scan
- New dependencies detected
- Architecture changes (new routes, new services, new tables)
- Staleness warnings for docs not updated in 90+ days

Codemap freshness is itself a Definition-of-Done item — `.github/PULL_REQUEST_TEMPLATE.md` asks for
CODEMAPS updates when routes, tables, or dependencies changed.

## Tips

- Focus on **high-level structure**, not implementation details
- Prefer **file paths and function signatures** over full code blocks
- Keep each codemap under **1000 tokens** for efficient context loading
- Use ASCII diagrams for data flow instead of verbose descriptions (fence them as `text`, per the
  `markdownlint-and-toolchain` skill — MD040 requires a language tag on every fence)
- Run after major feature additions or refactoring sessions
- Verify with `task repo:markdown` before committing
