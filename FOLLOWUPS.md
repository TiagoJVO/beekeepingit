# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `claude/cloud-provider-selection-69de9f` — Scaleway staging stand-up (D-26)

- **Switch staging's PWA image tag off the manual one-off once CI has actually built a real one.**
  `apps/staging/beekeepingit-helmrelease.yaml` and `environments/staging.yaml` both currently pin
  `pwa.image.tag: staging-manual` (a locally-built-and-pushed image, not CI's). CI now builds a
  proper `client-staging` variant (`.github/workflows/build-publish.yml`) tagged
  `staging-latest`/`staging-sha-<short>` — but that tag won't exist until _after_ this branch
  merges and the workflow runs on `main` for the first time (its `push:` step only fires on
  `github.event_name == 'push'`). Switch the tag over in a follow-up commit once confirmed to
  exist (`gh` / the ghcr.io package page), not before — pointing at it prematurely would break the
  live deployment.
- **Observability is intentionally not deployed anywhere** (dev, staging, or a future prod) —
  not a gap to revisit, a deliberate choice for now.
- Minor known trade-off, not blocking: the per-environment PWA URLs in
  `build-publish.yml`'s `detect` job and each `infra/helm/beekeepingit/environments/*.yaml` overlay
  are two independently-maintained copies of the same values (`global.appOrigin`,
  `gateway.appHost`/`authHost`, `services.oidc.issuerUrl` vs. `--dart-define` flags) — no shared
  source yet. Worth a GitHub issue if this drifts in practice; not urgent today.
