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

- **Live OIDC login→logout round trip against the real Keycloak is still unverified.** The
  implementation session's sandbox had no `flutter`/`helm`/`docker`/`k3d`/`kubectl`/`task`
  binaries installed at all, so nothing could be run locally before opening PR #166 — CI
  (`build client`: flutter analyze + flutter test + flutter build web; `k3d cluster + helm test`:
  full umbrella-chart install incl. the hardened realm ConfigMap into an ephemeral k3d cluster;
  `helm lint & template dry-run`) is now green and **did** catch two real bugs a local run would
  have (an invalid `const` in a test, and the new logout session-sweep throwing on the non-web
  stub platform in a widget test) — both fixed, CI re-run green. What CI's `k3d cluster + helm
  test` job does **not** exercise is an actual browser-driven OIDC login → logout → reload against
  the deployed Keycloak (it only asserts the chart installs and a Postgres smoke query passes) —
  that's the Playwright e2e's job (`client/e2e/tests/slice.spec.ts`'s new logout test), which isn't
  wired into this repo's PR-triggered CI (run manually/per `client/e2e/README.md`). **Before
  merge:** ideally have a teammate with cluster access run the e2e suite (or eyeball a manual
  login/logout) at least once against a live deploy of this branch, to confirm the RP-initiated
  end-session call actually revokes the Keycloak SSO session end-to-end (not just that the unit
  tests' mocked network call was made). Prune this entry once that's done or consciously waived.
