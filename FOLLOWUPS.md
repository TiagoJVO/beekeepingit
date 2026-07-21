# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Deploy pipeline (D-26, D-27) — post-merge remaining work

Phases 0–4 shipped in #330 (image-automation removed; `infra/gitops/` split into
`beekeepingit-gitops`; release-triggered `release-deploy.yml` + PWA build path), recorded in
[D-27](requirements/decisions.md) / [ADR-0018](docs/adr/0018-release-triggered-deploy-pipeline.md).
`DEPLOYMENT_PIPELINE_PLAN.md` stays until Phase 6 is done, then delete. Remaining:

- **Re-point the live dev cluster's Flux** (post-#330, manual, in WSL2) — if the dev cluster was
  GitOps-bootstrapped, `infra/gitops/` leaving `main` makes its Kustomization go stale:
  `git clone https://github.com/TiagoJVO/beekeepingit-gitops && kubectl apply -f beekeepingit-gitops/clusters/dev/`.
  No-op if you only use `dev-up.sh`'s local direct-apply loop.
- **Phase 5 — real domain `melargil.pt`** (naming confirmed, consistent `-rc`): prod
  `beekeepingit.melargil.pt` + `auth.beekeepingit.melargil.pt`; staging
  `beekeepingit-rc.melargil.pt` + `auth.beekeepingit-rc.melargil.pt`. In order, after the cluster
  is up so hosts resolve: (1) Scaleway reserved IP per env → Traefik's LoadBalancer; (2) Cloudflare
  A records (DNS-only) → those IPs; (3) swap the nip.io / `.example` values for the real ones in the
  gitops repo's `apps/{staging,prod}/beekeepingit-helmrelease.yaml`, `environments/{staging,prod}.yaml`,
  and `release-deploy.yml`'s `publish-client` dart-defines. cert-manager stays HTTP-01 unless the
  Cloudflare proxy is enabled.
- **Phase 6 — end-to-end verification** — bring staging up, cut `v0.0.1-rc1`, walk the whole chain
  (build → tag-bump PR → merge → Flux → real domain + trusted cert → login). First live exercise of
  the new pipeline.
- **Switch staging's PWA image tag off `staging-manual`** — the gitops repo's
  `apps/staging/beekeepingit-helmrelease.yaml` still pins `pwa.image.tag: staging-manual`; it
  switches automatically when the first `-rc` release's tag-bump PR sets the version and is merged
  (Phase 6). Don't hand-edit it to a non-existent tag before then.
- **Harden `main`'s required status checks** — tracked in **#368**; the remaining step is the
  repo-settings change itself (admin action). The in-repo prerequisites are done: `build-publish`
  now exposes the stable `build & scan images` aggregator and `contracts-ci` always runs. Add
  `build & scan images`, `OpenAPI breaking-change gate (oasdiff)`, `trivy (dependencies + secrets)`
  and `govulncheck (Go modules)` to the required set once those contexts have reported once on
  `main` (leave out `trivy (IaC / misconfig)`, which is report-only by design).
- **Observability is intentionally not deployed anywhere** (dev, staging, or a future prod) — a
  deliberate choice, not a gap to revisit.
- Minor, not blocking: the per-environment PWA URLs in `release-deploy.yml`'s `publish-client` job
  and each `infra/helm/beekeepingit/environments/*.yaml` overlay are two independently-maintained
  copies of the same values — no shared source yet. Worth a GitHub issue if it drifts.

## Not covered by an automated test: `todo_form_screen.dart`'s date picker

- **What**: actually driving the real `showDatePicker` calendar UI to pick a
  _new_ due date — only the pre-fill/display and the clear-button path are
  tested.
- **Why**: no existing precedent in this codebase for testing that
  interaction (`add_activity_screen.dart`'s own `occurredAt` date field is
  the same shape and isn't UI-driven in its own tests either).
- **Status**: not blocking; a reviewer wanting this covered should add it as
  a follow-up.
