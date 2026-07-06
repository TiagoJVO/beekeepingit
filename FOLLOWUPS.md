# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging the walking-skeleton slice (#23)

These are **deploy-time validation** items — the code/config/charts build, lint, render and
unit/integration-test green, but the following can only be confirmed against the live k3d
cluster (out of scope for the offline dev session; validate during the deploy/e2e/observability
ACs and adjust):

- **PowerSync Sync Rules** in `charts/powersync/values.yaml` (`request.jwt() ->>
'organization_id'`, edition-3 streams) are validated by PowerSync **at startup against the
  live schema**, not by `helm lint`. Confirm `powersync-service:1.23.2` accepts the stream
  syntax + token-claim accessor; adjust if rejected.
- **Keycloak issuer vs in-cluster reachability.** Services set `OIDC_ISSUER_URL` to the external
  gateway issuer (matching the token `iss`); in-cluster they must resolve that hostname. Add
  Keycloak `KC_HOSTNAME`/frontend-url config or `hostAliases` (→ the Traefik ClusterIP) so
  `go-oidc` discovery + issuer check pass. Classic Keycloak split-horizon wiring.
- **Postgres Service name + credential secret keys.** `charts/services/values.yaml`'s
  `db.host: beekeepingit-postgres-rw` and the `*-svc-credentials` `username`/`password` keys are
  the expected CNPG shapes — confirm against the live `Cluster` and adjust if they differ.
- **Gateway `/sync-stream` → PowerSync** is a naive prefix route; PowerSync appends its own
  paths, so it likely needs a Traefik `StripPrefix` middleware or a dedicated host. Validate the
  PWA↔PowerSync connection and add the middleware/host if needed.
- **PowerSync web assets.** `flutter build web` does not bundle the wasm SQLite + PowerSync
  workers; add the PowerSync web-asset copy step to the client build/Dockerfile so the PWA runs
  in the browser.
- **e2e in CI.** `client/e2e` (Playwright) needs the full slice deployed; wire a CI job that
  stands up the cluster (or targets a deployed env) and runs it. Until then it's a manual/local
  gate; the Go integration tests cover the server-side apply/coordinator semantics in CI now.
- **`powersync` publication scope change.** The postgres chart now publishes `FOR TABLES IN
SCHEMA apiaries, organizations` (was `FOR ALL TABLES`) per walking-skeleton.md §5.3. If the
  infra owner prefers the broader publication, this is a one-line revert — flag in review.
- **Re-run `infra/observability-smoke-test.sh`** against this slice's real traffic to close
  #87's deferred verification (the gateway→sync→apiaries trace in Tempo, per-service logs in
  Loki) — the NFR-OBS-1 M0 exit criterion.
