# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging `feat/EPIC-01-rbac-middleware` (#28)

- **No local Go toolchain in this sandbox**: `go`, `golangci-lint`, and Docker (for
  testcontainers-go) are not installed in the environment this branch was authored in, so
  `authn.RequireRole`/`authn.RequireOrgPath` ([`services/servicetemplate/authn/authz.go`](services/servicetemplate/authn/authz.go)),
  their tests ([`authz_test.go`](services/servicetemplate/authn/authz_test.go)), the
  `resolver.go` denial-logging change, and the new `apiaries` cross-org tests
  ([`main_test.go`](services/apiaries/main_test.go)) were written carefully by hand against the
  existing conventions but never compiled, vetted, or run locally. CI is the first real
  compile/test/lint pass — `ci.yml`'s repo-wide `task ci` covers `services/servicetemplate`
  (no Dockerfile ⇒ linted/tested once repo-wide, per `taskfiles/go.yml`), and
  `build-publish.yml`'s per-component matrix covers `services/apiaries` (has a Dockerfile).
  **Check both are green before merging.** Prune this entry once they've passed on the PR.
