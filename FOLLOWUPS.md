# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `claude/cloud-provider-selection-69de9f` — Scaleway staging stand-up (D-26)

- **Revert the temporary GitOps branch pointer before merge.**
  `infra/gitops/clusters/staging/flux-system.yaml`'s `GitRepository.spec.ref` is pinned to this
  feature branch (not `main`) so the live `beekeepingit-staging` Kapsule cluster could be
  bootstrapped and verified before merge. Must be flipped back to `branch: main` in the PR that
  merges this, per its own inline comment.
- **`environments/staging.yaml` overlay is still a stub**, not fleshed out to match what's
  actually deployed via `infra/gitops/apps/staging/*-helmrelease.yaml` (resource tiers, etc.) —
  only used for manual pre-merge `helm install -f` testing, doesn't block the Flux-managed path.
- **cert-manager support isn't wired into `charts/gateway/`** yet — the staging `HelmRelease`
  already carries `gateway.certManager.*`-shaped intent in `docs/architecture/platform.md`'s
  deferred-scope note, but the chart doesn't consume it, so staging currently falls back to
  self-signed TLS (same as dev). Blocks real trusted TLS once a domain is available (also still
  pending — no domain owned yet).
- **Observability stack (`infra/helm/observability/`) not deployed to staging** — deliberately
  deferred given `DEV1-M`'s tight memory budget; revisit once the core stack's actual footprint on
  the live cluster is known.
- **`apps/dev/beekeepingit-helmrelease.yaml` likely has the same install-time deadlock** as staging
  had before `install.disableWait`/`upgrade.disableWait` were added here: Helm's default
  wait-for-ready gates every Deployment before the release is considered successful, but
  `charts/postgres/templates/schema-grants-job.yaml` (a post-install/post-upgrade hook every
  DB-backed service and PowerSync depend on) only runs _after_ that wait succeeds — a from-scratch
  install can never converge. dev has never hit this because its Flux `HelmRelease` has only ever
  upgraded a release originally bootstrapped by a manual `helm install` (no `--wait` by default on
  the raw CLI). Untested risk: if dev's cluster is ever torn down and re-bootstrapped purely
  through Flux, it would deadlock the same way staging did. Consider applying the same
  `disableWait` fix there too, or fixing the chart's hook ordering itself so neither environment
  depends on this history quirk.
