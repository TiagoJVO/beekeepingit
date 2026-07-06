# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before merging the walking-skeleton slice (#23)

The slice was **deployed to a live k3d cluster** and driven **in a real browser** during
development. Working live: the whole backend stack (postgres, keycloak, minio, identity,
organizations, apiaries, sync, powersync, pwa) up 1/1; services DB-connected (`/readyz` 200);
`sync` serving its JWKS; **PowerSync replicating the synced tables**; and in the browser (via
the Playwright e2e) **OIDC login (Keycloak PKCE) → create an apiary → offline edit → local
persistence** all work end-to-end. Deploy bugs found and **fixed in this branch**: PowerSync
sync-rules → `bucket_definitions`; DB `search_path` + schema provisioned-by-infra; the
`powersync` role as a member of the `*_svc` roles; the OIDC issuer split-horizon (Keycloak
`KC_HOSTNAME` + the `keycloak-oidc` alias Service + CoreDNS rewrite + dev-overlay issuer +
realm redirect URI, so browser and in-cluster tokens agree); and `powersync:setup_web` folded
into the client build. What remains:

- **PowerSync browser → server write-back.** The one part not yet working live: after login the
  local-first create/edit persists in the browser's SQLite, but PowerSync's **sync client never
  starts** over the k3d **plain-HTTP** origin — `connect()` returns, the sync worker isn't
  spawned, the locks fallback emits no status, and `fetchCredentials`/`uploadData` never fire,
  so nothing reaches `/v1/sync/batch`. Root cause is the non-trustworthy HTTP origin (COOP/COEP
  are ignored ⇒ no cross-origin isolation ⇒ no SharedArrayBuffer). Fix by serving the dev PWA +
  gateway over **HTTPS** (or a trustworthy origin) so PowerSync's web sync runs; then the e2e's
  server-side + reload-convergence assertions pass. `client/e2e` already sets a
  `--host-resolver-rules` + `--unsafely-treat-insecure-origin-as-secure` launch flag; the
  remaining gap is the HTTPS/cross-origin-isolation topology, not the test.
- **Gateway `/sync-stream` → PowerSync** is a naive prefix route; PowerSync appends its own
  paths, so confirm the PWA↔PowerSync connection (once write-back runs) and add a Traefik
  `StripPrefix`/dedicated host if needed.
- **e2e in CI.** `client/e2e` (Playwright) needs the full slice deployed; wire a CI job that
  stands up the cluster (or targets a deployed env). The Go integration tests cover the
  server-side apply/coordinator semantics in CI now.
- **`powersync` publication scope change.** The postgres chart now publishes `FOR TABLES IN
SCHEMA apiaries, organizations` (was `FOR ALL TABLES`) per walking-skeleton.md §5.3. If the
  infra owner prefers the broader publication, this is a one-line revert — flag in review.
- **Re-run `infra/observability-smoke-test.sh`** against this slice's real traffic to close
  #87's deferred verification (the gateway→sync→apiaries trace in Tempo, per-service logs in
  Loki) — the NFR-OBS-1 M0 exit criterion.
