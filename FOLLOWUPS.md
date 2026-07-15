# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## `fix/go-shared-history-objectstore-tenancy`

- **`dbaccess.Config.validate()`'s new SearchPath check isn't wired into every DSN-building
  path** — found while fixing the HIGH #3 connection-string-injection finding
  (`services/shared/dbaccess/config.go`). `Connect()` calls `validate()` before `DSN()`, so
  that path is covered. But `Migrate()` takes a raw `dsn string`, not a `Config`, and every
  current caller (`services/{apiaries,identity,organizations}/main.go`) builds it via
  `cfg.DB.DSN()` directly, bypassing `validate()` entirely. In practice `SearchPath` there
  comes from each service's own env-configured, infra-trusted value (D-6 schema-per-service),
  not runtime user input, so this isn't currently exploitable — but the guard doesn't actually
  gate that call path. Options for a follow-up: have `Migrate` accept a `Config` (or a
  pre-validated DSN type) instead of a bare string, or have each service's config loader call
  `validate()` before handing the DSN to `Migrate`. Out of scope for this PR (would require
  touching `main.go` in three other services, beyond the mechanical `ComputeChange` call-site
  updates already carried here). Track as a GitHub issue if not picked up before this branch
  merges.
