# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging the API-contract CI branch (#153)

- This branch implements 3 of #153's 4 acceptance criteria: OpenAPI **lint**
  (`task openapi:lint`, `taskfiles/openapi.yml`), the **breaking-change gate** (`oasdiff`,
  `.github/workflows/contracts-ci.yml`), and **Go server-stub codegen wiring**
  (`task openapi:generate-go`, no-ops until a service adds `internal/api/oapi-codegen.yaml`).
  Dart/TS typed-client codegen is deferred — no client consumes a generated client yet and no
  tool is decided (not an AC blocker, `client/` just doesn't need it yet).
- **Do not close #153 when this PR merges** — the 4th AC, contract tests at service
  boundaries, needs a real deployed service to test against and is blocked on the walking
  skeleton ([#23](https://github.com/TiagoJVO/beekeepingit/issues/23)). Reference #153 in the
  PR body without `Closes`. Once #23 lands, add the contract-test job (e.g. against the
  `apiaries` service) and close #153 then.
- Prune this entry once that follow-up PR lands and #153 is actually closed.

## Before/after merging `renovate.json` (#155)

- **Install the [Renovate GitHub App](https://github.com/apps/renovate)** on this repo
  (Settings → GitHub Apps) — a one-time manual step in the GitHub UI that can't be scripted
  from here. `renovate.json` takes effect as soon as it's installed (no onboarding PR). Until
  then the config sits inert. Prune this entry once installed.
