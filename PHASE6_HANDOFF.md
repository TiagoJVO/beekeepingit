# Deploy-pipeline redesign — full handoff (Phases 0–5 done, Phase 6 pending)

Cold-start context for a peer agent (or human) picking this up with **zero prior knowledge**.
Everything below is already merged to `main` unless marked pending. When Phase 6 is done, delete
this file and `DEPLOYMENT_PIPELINE_PLAN.md` (the pre-execution plan doc, now largely historical).

**Durable records** (read these; this doc summarizes them): `requirements/decisions.md` → **D-26**
(cloud hosting) and **D-27** (this deploy model); `docs/adr/0018-release-triggered-deploy-pipeline.md`;
`docs/adr/0017-scaleway-cloud-hosting.md`; `docs/adr/0014-cicd-pipeline.md` (its §4 is superseded);
`FOLLOWUPS.md` (live pending-work ledger).

## 0. Project operating conventions (so you don't fight the repo)

- `requirements/` is the **source of truth for intent** (FR-_/NFR-_ requirements, `decisions.md`
  `D-*`, `open-questions.md` `Q-*`). `docs/` documents the **as-built** system (+ `docs/adr/` ADRs).
- Decisions/requirements are the working default and **revisitable only with user confirmation** —
  never silently diverge from a `D-*`. Cite IDs in branches/commits/PRs.
- The **backlog is GitHub Issues** (epics = `type/epic`), not a folder. `FOLLOWUPS.md` is the
  pre-merge / cross-session pending-work ledger — sweep it whenever you touch it; it trends to empty.
- `CLAUDE.md` is the repo map. Definition-of-done + mandatory-workflow rules live in `.claude/rules/`.
- Stack: Go backend services, Flutter PWA client, Helm umbrella chart, Flux GitOps, k3d for local
  dev, Scaleway Kapsule for cloud.

## 1. Background — why this work exists

**D-26 / ADR-0017:** the project picked **Scaleway Kapsule** (managed k8s, EU-region, cheap) as the
cloud host and stood up the first real `staging` cluster. That surfaced/fixed several latent
Helm/GitOps bugs (schema-grants install deadlock → `install.disableWait`; NetworkPolicy gateway
namespace `traefik` vs `kube-system`; Authentik blueprint redirect_uris templated per-env; node
`DEV1-M`→`DEV1-L`). Staging got trusted TLS via cert-manager + Let's Encrypt against **nip.io**
placeholder hostnames (no real domain yet). Staging is **currently torn down** to save cost;
`infra/cluster/scaleway-up.sh` recreates it on demand.

Then the branch designed an automated deploy pipeline — that design + implementation is **Phases 0–5**
below, decided in **D-27 / ADR-0018**.

## 2. The core decision (D-27 / ADR-0018) and the reasoning — do NOT re-litigate

**Deploy model: release-triggered, PR-based.** A published GitHub **Release** drives deploys:

- tag with `-rc` (e.g. `v0.0.1-rc1`) → **staging** (fast, no approval gate)
- bare tag (e.g. `v1.2.3`) → **prod** (gated by the `production` GitHub Environment's required
  reviewer). Prod is deferred to milestone M6 — no prod cluster/domain exists yet.

On release, CI builds/scans/publishes that version's images and opens a **tag-bump PR** against a
separate GitOps repo; a human merges it and **Flux** (read-only) reconciles.

**Why NOT Flux image-automation (the rejected approach):**

1. Flux's `image-automation-controller` auto-commits image-tag bumps to `main` — this needs Flux to
   hold a **standing git-write credential** (a deploy key). The user rejected granting that.
2. A "GitHub Environment approval then direct-push" variant is **impossible on this repo**: `main`
   requires PRs, and GitHub's "allow specified actors to bypass required PRs" is **org-repo-only**.
   `beekeepingit` is a **personal** repo (`owner_type: User`), so nothing but a repo-admin credential
   could push to `main` — the same standing secret, relocated. Hard platform limit, not a preference.
3. The release → CI-publishes → CI-opens-PR → human-merges → Flux-reconciles pattern needs **no
   standing credential anywhere** and works within the existing PR-only branch protection.

**GitOps repo split** (see §4): once the mechanism is PR-based, splitting `infra/gitops/` into its own
repo is pure structural hygiene, not a security trade-off.

## 3. Phases 0–5 — goal, what was done, and why (all merged)

| Phase | Goal                      | What was done / why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0** | Record the decision       | Added **D-27** to `requirements/decisions.md`, wrote **ADR-0018**, marked **ADR-0014 §4** (which chose image-automation) superseded. Records the decision so later phases cite a stable ID. Commit `57555e5` (in PR #330).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **1** | Purge image-automation    | Deleted the `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation` objects + the dormant `infra/gitops/image-automation/` dir; stripped every `$imagepolicy` setter marker from the dev/staging/prod HelmReleases; dropped `--components-extra=image-reflector,image-automation` from `flux install` in the bring-up scripts + docs → **Flux is read-only everywhere now**. Rewrote `platform.md`, the gitops README, the CODEMAP, ADR-0014, and chart comments to match. Commit `bfa889e`.                                                                                                                                                                                                                                                                                                               |
| **2** | Split the GitOps repo     | Created **`TiagoJVO/beekeepingit-gitops`** (public) holding `clusters/` + `apps/` (moved out of `infra/gitops/`). The Helm **chart** stays in `beekeepingit` (`infra/helm/beekeepingit/`). Each cluster's `flux-system.yaml` now has **two `GitRepository` objects**: `beekeepingit-gitops` (manifests) and `beekeepingit` (chart) — a supported Flux split. In `beekeepingit`: removed `infra/gitops/` + `gitops-ci.yml`; added `infra/cluster/gitops-dir.sh` (resolves a gitops checkout via shallow clone or `BEEKEEPINGIT_GITOPS_DIR`); rewired `dev-up.sh`/`dev-down.sh` (they apply the standalone Authentik/MinIO HelmReleases, which now live in the gitops repo) and `helm-e2e.yml` (a second `actions/checkout` of the gitops repo for the Authentik bring-up). Commit `681c68e` + the new repo. |
| **3** | Release-triggered deploy  | Reworked `.github/workflows/release-deploy.yml`. Jobs: `route` (parses the tag → target + GitHub Environment), `detect` (enumerate Go services), a single `approve` gate job (`environment:` = `staging` auto-created/ungated, or `production` = required-reviewer → **one approval for prod, not per-service**), `publish` (Go matrix: build → Trivy scan → push at the release version), `publish-client` (flutter build with the target env's `--dart-define` URLs → scan → push), and `open-pr` (checks out `beekeepingit-gitops` with the `GITOPS_PR_TOKEN` PAT, `sed`-bumps every image tag in `apps/<target>/beekeepingit-helmrelease.yaml`, opens the PR via `peter-evans/create-pull-request`). Commit `e55fbda`.                                                                                 |
| **4** | PWA build path            | The **only** deployable client build now lives in `release-deploy.yml` (per-target URLs baked in). `build-publish.yml`'s client became a single **define-less pure-CI** build (dev defaults) — also fixed a latent mismatch where nothing published plain `client:latest` yet the dev HelmRelease pinned `tag: latest`. Same commit `e55fbda`.                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **5** | Real domain `melargil.pt` | Chose **dynamic DNS** over a reserved IP: `scaleway-up.sh` pushes Traefik's LoadBalancer IP to Cloudflare A records on each bring-up (a held flexible IP bills ~€3/mo even while the cluster is down; we tear staging down to save cost). PRs: **#332** (dynamic DNS in `scaleway-up.sh`, gated on `CF_API_TOKEN`), **#333** (swap nip.io → melargil.pt in `environments/staging.yaml` + `release-deploy.yml` staging `--dart-define`s), **beekeepingit-gitops #1** (same swap in `apps/staging/beekeepingit-helmrelease.yaml`). Domain was corrected `.net` → `.pt` mid-way.                                                                                                                                                                                                                              |

## 4. Architecture as it stands

```text
Release published on beekeepingit
        │  (-rc → staging | bare → prod, gated)
        ▼
release-deploy.yml: build+scan+publish images (Go svcs + PWA)  →  open tag-bump PR
        │                                                              │ (GITOPS_PR_TOKEN)
        ▼                                                              ▼
   ghcr.io/tiagojvo/beekeepingit/*                        beekeepingit-gitops (apps/<env>/…)
                                                                       │ human merges PR
                                                                       ▼
                                              Flux (read-only) reconciles onto the cluster
                                              (chart from beekeepingit, manifests from gitops repo)
```

- **`beekeepingit`** — Go services, Flutter client, Helm umbrella chart (`infra/helm/beekeepingit/`),
  all workflows, `infra/cluster/*.sh` bring-up scripts.
- **`beekeepingit-gitops`** — `clusters/{dev,staging,prod}/` (bootstrap + cert-issuer) and
  `apps/{dev,staging,prod}/` (HelmReleases). Its own `gitops-ci.yml` (kubeconform).
- **dev** = local k3d (via `dev-up.sh`; deliberately NOT GitOps-bootstrapped — direct-applies).
  **staging** = Scaleway Kapsule. **prod** = inert scaffolding (deferred to M6).
- `build-publish.yml` = per-PR CI (lint/test/build/scan); its images are **artifacts, not
  deployables** under D-27.

## 5. GitHub settings / secrets inventory (already in place)

- **`GITOPS_PR_TOKEN`** — a fine-grained PAT scoped to `contents:write` + `pull_requests:write` on
  **`beekeepingit-gitops` only**, stored as an **Actions secret on `beekeepingit`**. Used by
  `release-deploy.yml`'s `open-pr` job. ⚠️ It **expires** — a silent failure mode (see §9).
- **`production` GitHub Environment** on `beekeepingit` with `TiagoJVO` as a required reviewer —
  gates the prod publish path.
- **`beekeepingit-gitops` `main` branch protection**: require a PR, 0 required approvals (solo
  self-merge OK) — makes D-27's "a human merges the tag-bump PR" real.
- **`beekeepingit` `main` required status checks** (`strict: true`): `ci`, `k3d cluster + helm test`
  (helm-e2e), `helm lint & template dry-run`, `Validate PR title (Conventional Commits)`.
- **Cloudflare** (for dynamic DNS) — you hold, NOT in git, passed as runtime env vars to
  `scaleway-up.sh`: `CF_API_TOKEN` (scoped Zone→DNS→Edit on melargil.pt) and `CF_ZONE_ID`.

## 6. Domain, DNS, cost

- **Staging:** app `beekeepingit-rc.melargil.pt`, auth `auth.beekeepingit-rc.melargil.pt`.
  **Prod (reserved, not built):** `beekeepingit.melargil.pt` / `auth.beekeepingit.melargil.pt`.
  Two hosts per env is required by ADR-0016 (PowerSync cross-origin isolation).
- **DNS:** Cloudflare, **DNS-only (not proxied)** so cert-manager HTTP-01 works. Dynamic — pushed by
  `scaleway-up.sh` each bring-up. No reserved IP.
- **Cost while staging runs:** LoadBalancer (LB-S) ~€16.8/mo (€0.023/hr) + `DEV1-L` node ~€30.66/mo.
  Both stop when you tear staging down. A reserved flexible IP would be ~€3/mo standing — avoided.

## 7. Current status — all PRs merged

| PR                         | Content                                                                        |
| -------------------------- | ------------------------------------------------------------------------------ |
| beekeepingit **#330**      | Phases 0–4 (decision + purge + repo split + release pipeline + PWA build path) |
| beekeepingit **#331**      | FOLLOWUPS note (required-checks hardening) + `.net`→`.pt` fix                  |
| beekeepingit **#332**      | Phase 5 — dynamic DNS in `scaleway-up.sh`                                      |
| beekeepingit **#333**      | Phase 5 — staging URL swap (code side)                                         |
| beekeepingit-gitops **#1** | Phase 5 — staging URL swap (Flux source of truth)                              |

Everything is merged and was green. Phase 6 has **never been run** — the release pipeline is
unexercised end-to-end (see §9).

## 8. Phase 6 — the go-live runbook (all in WSL2)

**Step 1 — bring up staging** (starts the cost meters):

```sh
CF_API_TOKEN=… CF_ZONE_ID=… \
STAGING_APP_HOST=beekeepingit-rc.melargil.pt STAGING_AUTH_HOST=auth.beekeepingit-rc.melargil.pt \
infra/cluster/scaleway-up.sh
```

Creates the Kapsule cluster, installs CNPG/Traefik/cert-manager/Flux, and pushes the DNS records to
Cloudflare.

**Step 2 — post-bring-up** (do the two things `scaleway-up.sh` prints at the end): create the
cert-manager `ClusterIssuer` (needs a real ACME account email), then bootstrap GitOps:

```sh
git clone https://github.com/TiagoJVO/beekeepingit-gitops
kubectl apply -f beekeepingit-gitops/clusters/staging/
```

**Step 3 — cut the release:** create a GitHub Release tagged **`v0.0.1-rc1`** on `beekeepingit`.
`release-deploy.yml` builds the PWA (melargil.pt URLs baked in) + Go services, scans, publishes, and
opens a tag-bump PR against `beekeepingit-gitops`.

**Step 4 — merge the tag-bump PR** → Flux reconciles the new image tags onto staging (also flips the
PWA off the `staging-manual` placeholder tag automatically).

**Step 5 — verify:** `https://beekeepingit-rc.melargil.pt` resolves with a trusted cert; OIDC login
via `auth.beekeepingit-rc.melargil.pt` works. That proves the whole pipeline end to end.

Expect ≥1 integration bug — first live run of the cross-repo PR + two-`GitRepository` Flux sourcing.

## 9. Known gaps / what's missing (audit — decide with the user)

1. **Promotion integrity** — nothing links the `-rc` tag (staging-tested) to the bare tag (prod);
   prod isn't guaranteed to be the same commit, and the PWA is a rebuild (env-specific URLs), not a
   bit-identical promotion. No enforcement — relies on discipline.
2. **No `concurrency:` guard on `release-deploy.yml`** — two releases could race the tag-bump PR.
3. **`GITOPS_PR_TOKEN` expiry = silent failure** of `open-pr`; no rotation reminder/monitoring.
4. **No post-deploy health verification / auto-rollback** after Flux reconciles.
5. **Migrations-on-deploy** strategy unstated (goose migrations on a rolling update).
6. **`beekeepingit-gitops` has no renovate/dependabot/PR-template** — its action pins + Flux CRD
   versions will drift.
7. **No guardrail against cutting a bare (prod) release** before prod exists.
8. **Release-cutting process undefined** — manual, no changelog/versioning automation.
9. **`release-deploy.yml` logic unexercised** until Phase 6 (actionlint validates syntax only).
   Also tracked in `FOLLOWUPS.md`: **harden `main`'s required checks** (add `security-scan`, a
   `build-publish` aggregator, and `contracts-ci` with the always-run pattern).

## 10. Other pending

- **Dev-cluster Flux re-point** (WSL2) — `infra/gitops/` left `main`, so IF the dev cluster was ever
  GitOps-bootstrapped, re-point it: `git clone …/beekeepingit-gitops && kubectl apply -f beekeepingit-gitops/clusters/dev/`.
  No-op if you only use `dev-up.sh`'s local direct-apply loop.
- Delete `DEPLOYMENT_PIPELINE_PLAN.md` and this file after Phase 6.

## 11. Gotchas / operating tips for this environment

- **`main` branch protection is `strict`** (require up-to-date): merging one PR bumps the others
  out-of-date. Either update-branch + auto-merge (re-runs the ~30–40 min helm-e2e) or, when a PR is
  already green with no real conflict, `gh pr merge <n> --squash --admin` (owner bypass).
- **`helm-e2e`** ("k3d cluster + helm test") is the slow required check (~30–40 min) and runs on
  every PR.
- **lefthook is NOT on PATH** in this Windows/Git-Bash env, so git hooks don't run — run the gate
  **manually** before pushing: `prettier@3` (the repo pins prettier `"3"` in `mise.toml`; validating
  with 3.3.x locally caused a false pass), `markdownlint-cli2`, and `shellcheck`
  (`npx --yes shellcheck <file>`) on touched files. **Never pipe `--check` to `tail`** — it masks the
  non-zero exit and you'll push an unclean file.
- **GitHub 503 outages** transiently failed the `Validate PR title` check repeatedly one night — it
  was infra, not the title. Re-run when GitHub is healthy (`gh api rate_limit` responding ≠ all
  endpoints healthy; check the actual run log for "No server is currently available").
- **Cloning to the session scratchpad hits Windows `MAX_PATH`** — use `git clone -c core.longpaths=true`.
- This worktree shares the git repo with the primary checkout at
  `C:/Users/tiago/Documents/GitHub/beekeepingit` (which holds `main`), so `gh pr merge --admin`'s
  local post-merge step errors with "'main' is already used by worktree" — **harmless**, the remote
  merge still lands.

## 12. Key file map

- Decisions: `requirements/decisions.md` (D-26, D-27) · ADRs `docs/adr/0018|0017|0014`.
- Bring-up: `infra/cluster/scaleway-up.sh` (staging + dynamic DNS), `dev-up.sh`/`dev-down.sh`,
  `gitops-dir.sh`, `with-lock.sh`.
- Chart/config: `infra/helm/beekeepingit/` (umbrella chart), `environments/staging.yaml`.
- Workflows: `.github/workflows/release-deploy.yml`, `build-publish.yml`, `helm-e2e.yml`.
- GitOps repo: `beekeepingit-gitops` → `clusters/<env>/flux-system.yaml` (two GitRepositories),
  `apps/<env>/beekeepingit-helmrelease.yaml`.
- Ledger/plan: `FOLLOWUPS.md`, `DEPLOYMENT_PIPELINE_PLAN.md` (historical).
