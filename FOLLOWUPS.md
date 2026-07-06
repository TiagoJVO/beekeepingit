# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging the walking-skeleton slice (#23)

The slice was **deployed to a live k3d cluster** during development: the whole backend stack
(postgres, keycloak, minio, identity, organizations, apiaries, sync, powersync, pwa) comes up
1/1, services are DB-connected (`/readyz` 200), `sync` serves its JWKS, and **PowerSync
replicates the synced tables** (snapshot done, checkpoints). Several deploy-time bugs found
there are **fixed in this branch** (PowerSync sync-rules → `bucket_definitions`; DB
`search_path` + schema provisioned-by-infra, not by migrations; the `powersync` role made a
member of the `*_svc` roles for snapshot SELECT). What remains:

- **Full browser auth — OIDC issuer split-horizon.** Services validate tokens against
  `OIDC_ISSUER_URL`, but in k3d the external host+port (`keycloak.beekeepingit.local:8443`)
  isn't reachable in-cluster (Traefik is on 443, not 8443). The live deploy worked around it by
  pointing services at the internal Keycloak Service (`--set services.oidc.issuerUrl=...`) — but
  then a browser-obtained token's `iss` (external) won't match. To make the PWA→services auth
  path work end-to-end, align on one issuer: expose the Keycloak Service on the k3d-mapped port
  (8080), set Keycloak's frontend URL to `http://keycloak.beekeepingit.local:8080`, add
  `hostAliases` on the service pods, and point both `OIDC_ISSUER_URL` and the PWA there; then
  drop the dev override.
- **Browser → gateway reachability for the Playwright e2e.** The headless browser must resolve
  `keycloak.beekeepingit.local` → 127.0.0.1 (hosts file, or Chromium `--host-resolver-rules`)
  and trust the self-signed cert. Wire this into the e2e run/CI.
- **Gateway `/sync-stream` → PowerSync** is a naive prefix route; PowerSync appends its own
  paths, so confirm the PWA↔PowerSync connection and add a Traefik `StripPrefix`/dedicated host
  if needed.
- **e2e in CI.** `client/e2e` (Playwright) needs the full slice deployed; wire a CI job that
  stands up the cluster (or targets a deployed env). The Go integration tests cover the
  server-side apply/coordinator semantics in CI now.
- **`powersync` publication scope change.** The postgres chart now publishes `FOR TABLES IN
SCHEMA apiaries, organizations` (was `FOR ALL TABLES`) per walking-skeleton.md §5.3. If the
  infra owner prefers the broader publication, this is a one-line revert — flag in review.
- **Re-run `infra/observability-smoke-test.sh`** against this slice's real traffic to close
  #87's deferred verification (the gateway→sync→apiaries trace in Tempo, per-service logs in
  Loki) — the NFR-OBS-1 M0 exit criterion.
