# 0018 — Deploy pipeline: release-triggered, PR-based promotion (replaces image-automation)

- **Status:** Accepted (supersedes [ADR-0014](0014-cicd-pipeline.md) §4)
- **Date:** 2026-07-19
- **Requirements:** NFR-ARC-3, NFR-MNT-1
- **Decisions:** [D-27](../../requirements/decisions.md) (this decision), builds on
  [D-13](../../requirements/decisions.md) (GitOps: Flux), [D-26](../../requirements/decisions.md) /
  [ADR-0017](0017-scaleway-cloud-hosting.md) (Scaleway hosting)
- **Design:** [`docs/architecture/platform.md#cicd`](../architecture/platform.md#cicd),
  [`.github/workflows/release-deploy.yml`](../../.github/workflows/release-deploy.yml)

## Context

[ADR-0014](0014-cicd-pipeline.md) §4 chose **Flux image-automation** to close the CI/CD loop: CI
publishes a commit-tagged image, then the `image-reflector` + `image-automation` controllers watch
the registry and **auto-commit** the new tag into Git for Flux to reconcile. Standing up the first
real cloud cluster (staging, ADR-0017) forced that dormant design to become real, and it hit a wall.

Image-automation's auto-commit requires Flux to hold a **standing git-write credential** (a deploy
key with write access to `main`). The user rejected granting that. Two alternatives were explored
and ruled out:

- **CI opens a PR, human approves** — no standing credential; viable (this is what we chose).
- **A GitHub Environment approval gate pushes directly** — a **dead end on this repo**: `main` has
  branch protection requiring PRs, and GitHub's "allow specified actors to bypass required pull
  requests" is **organization-owned-repo only**. `beekeepingit` is a **personal** repo
  (`owner_type: User`), so no workflow credential can push to `main` at all; only a repo-admin
  (owner) credential bypasses protection, which is the same standing write-secret merely relocated
  from Flux to GitHub Actions. This is a hard platform limitation, not a preference.

## Decision

### 1. One trigger: `release: published`, routed by tag suffix

A published GitHub Release is a deliberate, human-decided promotion event. One trigger type serves
both environments, routed by the tag:

- tag contains `-rc` (e.g. `v1.2.3-rc1`) → **staging** (fast, low-ceremony, no approval gate);
- tag has no `-rc` (e.g. `v1.2.3`) → **prod**, gated behind the `production` GitHub Environment's
  required-reviewer approval (that gate only guards the image-publish job — no git-write involved).

This replaces the earlier "staging deploys on every merge to `main`" idea: cutting an `-rc` release
is deliberate, so staging deploys become deliberate too, not continuous/noisy on every commit.

### 2. Promotion is a pull request, not an auto-commit (no standing credential)

On a release, CI builds and tags every buildable component with the **exact release version**, then
opens a small tag-bump **PR** against the GitOps state (via `peter-evans/create-pull-request`). A
human reviews the one-line-per-component diff and merges it through the same required status checks
as any other PR. Flux — **unchanged, still purely read-only** — reconciles the merge. This is the
same pattern Dependabot already uses here, and needs no standing git-write credential anywhere.

### 3. GitOps manifests move to a separate `beekeepingit-gitops` repo

`infra/gitops/` (the `HelmRelease`/`GitRepository`/`Kustomization` objects and per-environment
overrides) moves to its own repo; the Helm **chart** (`infra/helm/beekeepingit/`) stays in this
repo. Flux sources the chart from this repo (`HelmRelease.chart.spec.sourceRef`) and the
release-manifests from the new one (the bootstrap `GitRepository`) — a normal, supported split. With
promotion now PR-based rather than direct-push, this is pure structural hygiene, not a security
trade-off. `release-deploy.yml` (which lives here, where releases are cut) opens its tag-bump PR
against the new repo, which requires a scoped token or a small GitHub App installed on both repos.

### 4. `build-publish.yml` is pure CI; the only deployable build is release-triggered

`build-publish.yml` reverts to lint/test/build/scan on every PR and merge — a quality gate whose
published images are build artifacts, not deployables. The **only** build that produces a real,
promotable artifact (Go services and the per-environment PWA alike) is `release-deploy.yml`, tagged
with the release version. This gives one consistent mental model: CI validates every change;
`release-deploy.yml` is the single origin of anything that deploys.

## Consequences

- No component holds a standing git-write credential; the pipeline works within `main`'s existing
  PR-only branch protection, unchanged.
- The `image-reflector`/`image-automation` controllers are no longer needed — `flux install` drops
  `--components-extra`, and the `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation` objects and
  `$imagepolicy` setter markers are removed across `dev`/`staging`/`prod`.
- A deploy is now a reviewed PR + merge, not a machine auto-commit — slightly more ceremony, in
  exchange for zero standing write-secrets and a human eye on every tag bump.
- The cross-repo PR step needs a scoped credential (token/GitHub App) — narrower than the rejected
  Flux deploy key (it can only open a PR, not push to `main`), but still a secret to manage; tracked
  in `FOLLOWUPS.md`.
- Rollback stays a Git operation (`git revert` the tag-bump PR in the GitOps repo), same as before.

## Alternatives considered

- **Flux image-automation (ADR-0014 §4)** — superseded: requires a standing git-write credential the
  user rejected, and its direct-push model cannot satisfy this repo's PR-only protection anyway.
- **Direct push after a GitHub Environment approval** — impossible here (personal repo; PR-bypass is
  org-only), see Context.
- **Repo-admin (owner) credential in GitHub Actions** — would push successfully (owners bypass
  protection), but is a standing write-capable secret, exactly what §2 avoids.
- **Keep `infra/gitops/` in this repo** — viable and simpler (same-repo PR needs only `GITHUB_TOKEN`,
  no new secret); the split (§3) was chosen for separation-of-concerns hygiene, accepting the
  cross-repo credential cost.

## Addendum (2026-07-21): separate the approval-gate environment from the deploy-record environment

`beekeepingit`'s [Deployments page](https://github.com/TiagoJVO/beekeepingit/deployments) is
populated by Actions' implicit deployment-record creation, triggered any time a job references
`environment:` — there's no separate API call to intercept. Before this change, `approve` referenced
`staging`/`production` directly, so the Deployments page recorded "approved to publish" at release
time — before the tag-bump PR was even opened, let alone merged into `beekeepingit-gitops`. That
conflated two different events under one name: _approved to release_ and _actually running on the
cluster_.

**Change:** `approve` now references `staging-gate`/`production-gate` (this repo's only user of
those names). The required-reviewer protection rule moved from `production` to `production-gate`;
`production`/`staging` are now unprotected placeholders, reserved for the real deploy record.
`beekeepingit-gitops`'s `notify-deploy` workflow (fires on push to its `main`, i.e. exactly when a
tag-bump PR merges and Flux is about to reconcile) creates a deployment on `beekeepingit` under the
plain `staging`/`production` name via a scoped cross-repo PAT (`DEPLOY_NOTIFY_TOKEN`, Deployments:
write on `beekeepingit` only — same narrow-scope principle as `GITOPS_PR_TOKEN` in §2/§3).

Consequence: `beekeepingit`'s Deployments page now carries two distinct environment families —
`*-gate` (release approved to publish) and the plain name (GitOps merge landed, Flux reconciling)
— rather than one name meaning both. No change to the approval mechanism itself, no new standing
git-write credential (the new PAT can only create deployment records, nothing else).
