# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Before/after merging `renovate.json` (#155)

- **Install the [Renovate GitHub App](https://github.com/apps/renovate)** on this repo
  (Settings → GitHub Apps) — a one-time manual step in the GitHub UI that can't be scripted
  from here. `renovate.json` takes effect as soon as it's installed (no onboarding PR). Until
  then the config sits inert. Prune this entry once installed.

## Before merging `feat/EPIC-01-keycloak-oidc-hardening` (#24)

- **CI must confirm what this branch's sandbox couldn't run locally.** The implementation
  session had no `flutter`/`helm`/`docker`/`k3d`/`kubectl`/`task` binaries available at all
  (not just no live cluster — the toolchains themselves aren't installed in that sandbox), so
  none of `flutter analyze`, `flutter test`, `helm lint`/`helm template`, or a live-cluster
  logout/email-verification/token-lifetime check could be run before opening the PR. Everything
  was reviewed statically (lint rules in `client/analysis_options.yaml` cross-checked by hand:
  `require_trailing_commas`, `prefer_single_quotes`, `directives_ordering`; realm JSON validated
  with a plain JSON parser only). **Before merge:** confirm `build-publish.yml`'s `client`
  job (flutter analyze + flutter test) is green, and ideally have a teammate with cluster access
  do one live pass — log in → log out → confirm the Keycloak SSO session is actually revoked
  (not just the local token), and a reload doesn't silently re-auth — plus `helm lint`/
  `helm template` on `infra/helm/beekeepingit/charts/keycloak`. Prune this entry once CI is green
  and, ideally, that live pass has happened (or been consciously waived).
