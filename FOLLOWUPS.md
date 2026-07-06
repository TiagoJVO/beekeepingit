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
server-side assertion (`GET /v1/apiaries` reflects the edit) → reload convergence → a second
fresh client converges via download sync** — passes end-to-end, exercising **both** the
PowerSync browser → server write-back and the server → client download. Deploy bugs found and
**fixed in this branch**: PowerSync sync-rules → `bucket_definitions`; DB `search_path` + schema
provisioned-by-infra; the `powersync` role as a member of the `*_svc` roles; the OIDC topology
(see below); and the two stacked download-sync bugs (gateway route targeted a non-existent
`powersync` Service so `/sync-stream` fell through to the PWA; and the client's PowerSync
endpoint lacked a trailing slash, so the SDK's `Uri.resolve` dropped the `/sync-stream` prefix
and POSTed to `/sync/stream` → PWA 405 — both fixed, plus a Traefik StripPrefix for the route).
What remains:

- **e2e in CI.** `client/e2e` (Playwright) needs the full slice deployed; wire a CI job that
  stands up the cluster (or targets a deployed env). The Go integration tests cover the
  server-side apply/coordinator semantics in CI now.
- **CI/CD deploy — auto-deploy loop is merge-gated + blocked on EPIC-14 #89.** AC#5's build/
  publish half is done and verified: `build-publish.yml` builds, tests, Trivy-scans, and (on
  merge to `main`) **publishes** SHA-timestamp-tagged images to ghcr.io. The **deploy** half is
  Flux image-automation (`infra/gitops/image-automation/`) — engine + convention committed and
  CI-schema-valid, but deliberately **dormant**: activating it needs (a) a merge so ghcr images
  exist, and (b) a Flux **Git-write credential**, which the image-automation README itself pins
  to **EPIC-14 [#89](https://github.com/TiagoJVO/beekeepingit/issues/89)** (secrets), out of #23.
  It also still needs the per-service `ImageRepository`/`ImagePolicy` (copied from the `gateway`
  example) + setter markers on the slice's image tags — and a decision on the local-`:latest`
  vs GitOps-SHA-tag split so activation doesn't break the manual dev loop. Pre-merge the slice is
  deployed via the manual `helm upgrade` path (dev-up.sh), by design.
- **`powersync` publication scope change.** The postgres chart now publishes `FOR TABLES IN
SCHEMA apiaries, organizations` (was `FOR ALL TABLES`) per walking-skeleton.md §5.3. If the
  infra owner prefers the broader publication, this is a one-line revert — flag in review.
- **Observability stack lives in its own release (#87), not the dev bring-up.** NFR-OBS-1 is
  **verified live**: with `infra/helm/observability` (OTel Collector + Tempo + Loki + Grafana)
  deployed and e2e traffic driven through it, Tempo holds a single **gateway → sync → apiaries**
  trace (Traefik span via [`traefik-tracing.yaml`](infra/gitops/apps/dev/traefik-tracing.yaml)),
  Loki holds trace-correlated per-service structured logs, and `observability-smoke-test.sh`
  passes (see walking-skeleton.md §11.3). The remaining follow-up is purely wiring the stack
  into the standard bring-up / GitOps sync so it comes up automatically (owned by #87), rather
  than the manual `helm upgrade --install observability` used to verify here.
