# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `claude/cloud-provider-selection-69de9f` — Scaleway staging + deploy pipeline (D-26, D-27)

### Deploy pipeline redesign (D-27 / ADR-0018) — remaining gated phases

Mechanism now recorded in [D-27](requirements/decisions.md) /
[ADR-0018](docs/adr/0018-release-triggered-deploy-pipeline.md); the abandoned Flux image-automation
has been removed. The full multi-phase plan lives in `DEPLOYMENT_PIPELINE_PLAN.md` (a working
handoff doc — delete once executed). Remaining phases, each gated on user confirmation or an
outward-facing action:

- **Split `infra/gitops/` into a `beekeepingit-gitops` repo** (Phase 2) — needs `gh repo create`,
  re-points the live dev cluster's Flux `GitRepository`, reworks the bring-up scripts' bootstrap
  step. Direction confirmed (D-27); repo creation itself still to be approved.
- **Rework `release-deploy.yml`** (Phase 3) — add `-rc`→staging / bare-tag→prod routing and the
  release→tag-bump-PR step against the new repo. Needs a scoped token / GitHub App for the
  cross-repo PR (a new standing secret — pending sign-off).
- **PWA build path** (Phase 4) — move the only deployable client build into `release-deploy.yml`
  (tagged by release version), leaving `build-publish.yml` as pure CI. Coupled to Phase 3 (same
  file); this also resolves the current `build-publish.yml` per-env client matrix and the
  `client:latest` vs. dev HelmRelease `tag: latest` mismatch.
- **Real domain `melargil.net`** (Phase 5) — 4 hostnames (app+auth × staging+prod, ADR-0016),
  Scaleway reserved IPs, Cloudflare DNS. Subdomain naming still to confirm with the user.
- **End-to-end verification** (Phase 6) — bring staging up, cut `v0.0.1-rc1`, walk the whole chain.

### Other

- **Switch staging's PWA image tag off `staging-manual`** once the release-triggered client build
  (Phase 4) produces a real per-environment image. `apps/staging/beekeepingit-helmrelease.yaml` and
  `environments/staging.yaml` both pin `pwa.image.tag: staging-manual` (a locally-built-and-pushed
  image). Resolves when Phase 4 lands, not before — pointing at a non-existent tag would break the
  deploy.
- **Observability is intentionally not deployed anywhere** (dev, staging, or a future prod) —
  not a gap to revisit, a deliberate choice for now.
- Minor known trade-off, not blocking: the per-environment PWA URLs in the client build workflow
  and each `infra/helm/beekeepingit/environments/*.yaml` overlay are two independently-maintained
  copies of the same values (`global.appOrigin`, `gateway.appHost`/`authHost`,
  `services.oidc.issuerUrl` vs. `--dart-define` flags) — no shared source yet. Phase 4 may
  consolidate; worth a GitHub issue if it drifts. Not urgent today.
