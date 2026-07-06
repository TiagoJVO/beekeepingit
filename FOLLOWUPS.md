# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging the walking-skeleton slice (#23)

The slice was **deployed to a live k3d cluster** and driven **in a real browser**: the full
Playwright e2e — **OIDC login (Keycloak PKCE) → create an apiary → offline edit → reconnect →
server-side assertion (`GET /v1/apiaries` reflects the edit) → reload convergence** — passes
end-to-end, including the **PowerSync browser → server write-back**. Deploy bugs found and
**fixed in this branch**: PowerSync sync-rules → `bucket_definitions`; DB `search_path` + schema
provisioned-by-infra; the `powersync` role as a member of the `*_svc` roles; and the OIDC
topology (see below). What remains:

- **e2e in CI.** `client/e2e` (Playwright) needs the full slice deployed; wire a CI job that
  stands up the cluster (or targets a deployed env). The Go integration tests cover the
  server-side apply/coordinator semantics in CI now.
- **`powersync` publication scope change.** The postgres chart now publishes `FOR TABLES IN
SCHEMA apiaries, organizations` (was `FOR ALL TABLES`) per walking-skeleton.md §5.3. If the
  infra owner prefers the broader publication, this is a one-line revert — flag in review.
- **Full observability stack (Tempo/Loki/Grafana) is still deferred (#87)** — the dev bring-up
  deliberately skips it. The **distributed trace was verified live** against a throwaway OTLP
  collector (debug exporter): a single trace spans `sync → apiaries → identity → organizations`
  on the `/v1/sync/batch` write-back (W3C `traceparent` propagated across the internal REST
  calls), satisfying NFR-OBS-1's east-west requirement. The Tempo/Grafana *visualization* +
  `infra/observability-smoke-test.sh` on real traffic still ride on the #87 stack deploy.
