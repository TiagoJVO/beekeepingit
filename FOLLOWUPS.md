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
What remains — all tracked elsewhere; nothing blocks the merge:

- **e2e in CI** → promoted to **[#162](https://github.com/TiagoJVO/beekeepingit/issues/162)**.
  The Playwright e2e passes live but isn't a CI job yet (Go integration tests cover the
  server-side semantics in CI now); that issue also folds in per-run test-data teardown.
- **CI/CD auto-deploy — post-merge, gated on EPIC-14 [#89](https://github.com/TiagoJVO/beekeepingit/issues/89).**
  Build/publish is done and verified (`build-publish.yml` publishes SHA-tagged images on merge).
  The deploy half — Flux image-automation for the slice's 5 images — is **wired but dormant**
  (`infra/gitops/image-automation/slice-service-images.yaml` + setter markers in the umbrella
  HelmRelease); activation needs a merge (so ghcr images exist) + a Flux Git-write credential
  (#89), and moving those objects into a reconciled path. Documented in that directory's README.
- **Observability into the standard bring-up (#87).** NFR-OBS-1 is **verified live** (Tempo holds
  the gateway → sync → apiaries trace, Loki holds trace-correlated per-service logs,
  `observability-smoke-test.sh` passes — walking-skeleton.md §11.3). The stack was deployed by
  hand; folding it into `dev-up.sh`/GitOps so it comes up automatically is #87.

_Confirmed (no longer open): the `powersync` publication is intentionally scoped to
`FOR TABLES IN SCHEMA apiaries, organizations` (least-privilege, not `FOR ALL TABLES`) —
walking-skeleton.md §5.3._
