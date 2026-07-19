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
handoff doc — delete once executed). Phase status on this branch, and the remaining gated work:

- **Phase 2 (GitOps repo split) — DONE on this branch.** `TiagoJVO/beekeepingit-gitops` created and
  populated; `infra/gitops/` removed here; `dev-up.sh`/`dev-down.sh`/`scaleway-up.sh`/`helm-e2e.yml`
  rewired to source manifests from the new repo (via `infra/cluster/gitops-dir.sh` or a second CI
  checkout). **Post-merge action (manual, your cluster):** re-point the live dev cluster's Flux at
  the new repo — `git clone https://github.com/TiagoJVO/beekeepingit-gitops && kubectl apply -f
beekeepingit-gitops/clusters/dev/` — else its Kustomization goes stale when `infra/gitops/` leaves
  `beekeepingit@main`. (The new repo also wants branch protection on `main` before Phase 3 wires the
  tag-bump PR into it.)
- **Phase 3 (release-deploy rework) — DONE on this branch.** `release-deploy.yml` now routes
  `-rc`→staging / bare-tag→prod, gates prod via a single `approve` job on the `production`
  Environment, builds+scans+pushes every service + the PWA at the release version, and opens a
  tag-bump PR against `beekeepingit-gitops` via `peter-evans/create-pull-request` +
  `GITOPS_PR_TOKEN`. Credential = fine-grained PAT (`GITOPS_PR_TOKEN` secret) — **created ✓**;
  `beekeepingit-gitops` `main` branch protection — **set ✓**. Not exercised end-to-end until a
  release is cut (Phase 6).
- **Phase 4 (PWA build path) — DONE on this branch.** The only deployable client build lives in
  `release-deploy.yml` (per-target `--dart-define` URLs, tagged by release version);
  `build-publish.yml`'s client is now a single define-less pure-CI build, which also resolves the
  old per-env client matrix and the `client:latest` vs. dev HelmRelease `tag: latest` mismatch
  (`client:latest` now carries dev-default URLs, which is what dev's Flux path pulls).
- **Real domain `melargil.net`** (Phase 5) — 4 hostnames (app+auth × staging+prod, ADR-0016),
  Scaleway reserved IPs, Cloudflare DNS. Subdomain naming still to confirm with the user.
- **End-to-end verification** (Phase 6) — bring staging up, cut `v0.0.1-rc1`, walk the whole chain.

### Other

- **Switch staging's PWA image tag off `staging-manual`.** The gitops repo's
  `apps/staging/beekeepingit-helmrelease.yaml` (and this repo's `environments/staging.yaml`) still
  pin `pwa.image.tag: staging-manual` (a locally-built one-off). The Phase 3/4 mechanism is in
  place, but the tag only actually switches when the first `-rc` release's tag-bump PR sets
  `pwa.image.tag` to the release version and is merged (Phase 6) — don't hand-edit it to a
  non-existent tag before then.
- **Observability is intentionally not deployed anywhere** (dev, staging, or a future prod) —
  not a gap to revisit, a deliberate choice for now.
- Minor known trade-off, not blocking: the per-environment PWA URLs in `release-deploy.yml`'s
  `publish-client` job and each `infra/helm/beekeepingit/environments/*.yaml` overlay are two
  independently-maintained copies of the same values (`global.appOrigin`, `gateway.appHost`/
  `authHost`, `services.oidc.issuerUrl` vs. `--dart-define` flags) — no shared source yet (Phase 4
  did not consolidate them). Worth a GitHub issue if it drifts. Not urgent today.
