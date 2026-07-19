# Deployment pipeline — context + plan for the next session

Written to let a fresh session pick this up with zero prior context. Branch:
`claude/cloud-provider-selection-69de9f`, not yet merged to `main`. This file is a
working handoff doc, not permanent project documentation — delete it once the
plan below is executed and the durable decisions are recorded in
`requirements/decisions.md`/`docs/adr/` as usual.

## 1. Background — what this branch is and why

D-26 chose **Scaleway Kapsule** as the cloud hosting provider (see
`requirements/decisions.md#d-26` and
[`docs/adr/0017-scaleway-cloud-hosting.md`](docs/adr/0017-scaleway-cloud-hosting.md)).
This branch stood up the first real cloud cluster (`staging`), found and fixed a
number of real bugs that only a genuinely fresh cloud deployment surfaces, and got
login working end-to-end. It then moved on to designing an automated deploy
pipeline (dev/staging/prod), which is the part still in flux (pun intended) — see
§3 for where that landed and §4 for the new plan.

**Current live state**: the staging Kapsule cluster was **torn down** (cost-saving,
explicit user request) — nothing is running in Scaleway right now.
`infra/cluster/scaleway-up.sh` recreates it on demand (defaults to `DEV1-L`, `fr-par`,
latest-supported k8s version — all overridable via env vars, see the script's own
comments).

## 2. What's already done on this branch (commits, oldest first)

1. `docs(requirements)`: recorded D-26 in `requirements/decisions.md` +
   `requirements/tech-stack.md`.
2. `feat(infra)`: `infra/cluster/scaleway-up.sh`/`scaleway-down.sh` (idempotent
   bring-up/teardown, mirrors `up.sh`/`down.sh`), `infra/gitops/clusters/staging/` +
   `infra/gitops/apps/staging/` (mirrors `dev`'s layout).
3. A string of **real bugs found via live bring-up**, each fixed and documented in
   its own commit (see `git log` on this branch for full messages) — also written
   up in [ADR-0017](docs/adr/0017-scaleway-cloud-hosting.md):
   - Duplicate YAML key in staging's `beekeepingit-helmrelease.yaml`.
   - **Helm install hook deadlock**: `charts/postgres/templates/schema-grants-job.yaml`
     (a post-install hook every DB-backed service + PowerSync need) only runs after
     Helm's wait-for-ready succeeds, but the Deployments can't pass that wait
     without the hook — hard deadlock on any from-scratch install. Fixed via
     `install.disableWait: true` on **both** `apps/staging/` and
     `apps/dev/beekeepingit-helmrelease.yaml` (dev's was precautionary — its Flux
     release has only ever _upgraded_, never done a from-scratch install, so it
     never hit this, but would if the dev cluster were ever rebuilt via Flux alone).
   - **Authentik blueprint's `redirect_uris` were dev-hardcoded** — a static file
     (`.Files.Get` never processes `{{ }}`), fixed by rendering it through `tpl` and
     a new shared `global.appOrigin` value.
   - **`NetworkPolicy` gateway-namespace mismatch** — every gateway→backend edge
     hardcoded `kube-system` (correct for k3d/dev), wrong for Scaleway (Traefik
     installs into its own `traefik` namespace here) — silently blocked all
     Traefik→backend traffic, not just cert-manager's ACME solver pods (which
     additionally had no edge at all). Fixed via a `gatewayNamespace` value + a
     `__gateway__` sentinel (values.yaml isn't template-rendered, so the
     substitution happens in the one template that needs it).
   - **PWA login failure** — the PWA's OIDC/gateway/PowerSync URLs are Dart
     **compile-time** constants (`client/lib/core/config/app_config.dart`,
     `--dart-define`), and CI never passed environment-specific ones, so every
     published image had dev's `.local` URLs baked in regardless of where it
     deployed. Worked around with a manually-built-and-pushed image
     (`client:staging-manual`); CI was then taught to build proper per-environment
     variants (`client-dev`, `client-staging`) — **this may change again under the
     new plan, see §4.3**.
   - Node was resized `DEV1-M` → `DEV1-L` after confirming via `kubectl top node`
     that the full stack's memory requests hit ~90% of `DEV1-M`'s allocatable.
4. `feat(infra)`: cert-manager wired into `charts/gateway/` (mutually exclusive
   with the existing self-signed cert template), staging switched to **nip.io**
   hostnames (`app.51-159-204-90.nip.io` / `auth.51-159-204-90.nip.io`) for real,
   publicly-resolvable TLS since no domain was available yet — **now superseded,
   see §5, the user has a real domain**.
5. `docs`: [ADR-0017](docs/adr/0017-scaleway-cloud-hosting.md), `platform.md`
   updates, `FOLLOWUPS.md`.
6. Scope for the deploy-trigger pipeline was set: **dev stays local/manual (out of
   scope — CI can't reach it, it's a k3d cluster on a dev machine)**, **staging
   deploys automatically**, **prod deploys only on an approved release**.
7. `feat(infra)`: prod's GitOps scaffold created from scratch
   (`infra/gitops/{clusters,apps}/prod/`), mirroring staging's fixed pattern —
   **not deployed anywhere**, inert until a real prod cluster exists (D-26 defers
   this until `Q-DR`/`#90` land at M6).
8. `feat(infra)`: `environments/staging.yaml` and `environments/prod.yaml` fleshed
   out from stubs.
9. `feat(infra)`: Flux image-automation activated for staging AND prepared
   (inert) for prod — `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`
   objects, `$imagepolicy` setter markers in both HelmRelease files.
   **⚠️ This is now being reconsidered/likely reverted — see §3 and §4.1.**
10. `feat(ci)`: `.github/workflows/release-deploy.yml` — release-triggered,
    approval-gated prod image publish. **Needs rework under the new plan, see
    §4.2.**
11. Created the `production` GitHub Environment with `TiagoJVO` as required
    reviewer (via `gh api`, not in git — this is a GitHub repo setting, not a
    file).

## 3. Why the image-automation approach is being abandoned

Long back-and-forth, worth preserving the reasoning so it doesn't get re-litigated:

1. **Original design**: Flux's `image-automation-controller` watches the registry
   and auto-commits tag bumps back to `main`. This is a real, documented Flux
   feature (not invented for this project) — but requires Flux to hold a
   **persistent, standing git-write credential** (a deploy key).
2. User pushed back hard on granting this. Investigated whether the _"CI opens a
   PR, human approves"_ alternative was viable instead (no standing credential).
3. Investigated a _"GitHub Environment approval gate directly pushes"_ hybrid —
   **dead end**: `main` has branch protection requiring PRs
   (`required_pull_request_reviews`), and this repo is a **personal repo**
   (`owner_type: User`, confirmed via `gh api repos/.../beekeepingit`) — GitHub's
   "allow specified actors to bypass required pull requests" feature is
   **only available for organization-owned repos**. So a direct-push design
   (Flux's original one, or a workflow pushing after an environment approval)
   **cannot work on this repo at all**, full stop — not a preference, a hard
   platform limitation. The only thing that _would_ push successfully is a
   credential belonging to a repo **admin** (owners bypass branch protection by
   default here — confirmed `enforce_admins: false`), which is a real option but
   still a standing write-capable secret, just relocated from Flux to a GitHub
   Actions secret.
4. **Landed on**: a release-triggered, PR-based pattern (§4) — no standing
   credential anywhere, works within the existing branch protection as-is, and
   uses a release-tag-suffix convention (`-rc` vs not) to route staging vs prod
   through one unified mechanism instead of two different trigger types
   (merge-to-main vs release-published).

**Action for next session**: remove the now-dead Flux image-automation objects —
`infra/gitops/clusters/staging/{image-automation,service-images}.yaml`,
`infra/gitops/clusters/prod/{image-automation,service-images}.yaml` — and the
`$imagepolicy` setter-marker comments in both `apps/{staging,prod}/beekeepingit-helmrelease.yaml`
files (harmless to leave the plain `tag:` values, just drop the marker comments
since nothing will ever act on them).

## 4. New plan: release-triggered, PR-based deploy pipeline

### 4.1 Trigger convention

One trigger type instead of two: **`release: published`**, both environments.

- Release tag contains `-rc` (e.g. `v1.2.3-rc1`) → deploy to **staging**.
- Release tag has no `-rc` (e.g. `v1.2.3`) → deploy to **prod**, gated behind the
  already-created `production` GitHub Environment approval (§2.11) — that gate
  stays exactly as built, it only gates the **image publish** step, no git-write
  involved, nothing to rework there.

This replaces the earlier "staging deploys on every merge to `main`" idea — cutting
an `-rc` release is a deliberate action, so staging deploys become deliberate too,
not continuous/noisy on every commit. Also replaces needing two different workflow
triggers (`push: branches: [main]` vs `release: published`) with one.

### 4.2 Mechanism (no standing credential anywhere)

1. Release published → CI builds + tags every Go service (and, once §4.3 below is
   resolved, the PWA) with the **exact release tag** (`v1.2.3-rc1` or `v1.2.3`).
2. For the prod path only: push is gated behind the `production` environment
   approval (already built in `release-deploy.yml` — reuse that job shape).
   For the `-rc`/staging path: push happens immediately, no gate (matches
   staging's "fast, low-ceremony" role).
3. CI opens a small, auto-generated PR — using a well-known action like
   `peter-evans/create-pull-request` and the workflow's own ordinary
   `GITHUB_TOKEN` (already present, already scoped to just that run, not a new
   secret) — bumping the target environment's `apps/{staging,prod}/beekeepingit-helmrelease.yaml`
   (or the new repo's equivalent path, see §4.4) tag fields to the release
   version. This is the exact same pattern Dependabot already uses in this repo
   for dependency bumps.
4. User reviews (a one-line-per-service diff, easy to read) and merges — same as
   any other PR, goes through the same required status checks.
5. Flux (unchanged, still purely read-only, same as it's always been) picks up the
   merge and reconciles. No change to how Flux itself works, anywhere.

**Rework needed on `release-deploy.yml`**: add the `-rc`-suffix branching (which
target environment), add the PR-opening step (currently the workflow only
publishes images, doesn't touch the GitOps state at all — that's the piece that
was still missing even before the credential debate).

### 4.3 Open question: does the PWA still need a per-environment CI build?

`build-publish.yml` currently builds `client-dev`/`client-staging` variants on
every merge to `main` (§2, item 3's workaround, formalized in commit `53a3766`).
Under the new release-triggered plan, **deploys no longer come from merge-triggered
builds at all** — only from release-triggered ones. Worth reconsidering whether:

- (a) Keep `build-publish.yml` as pure CI (lint/test/build/scan on every PR/merge,
  quality-gate only, **not** tied to any deploy path — the images it publishes
  become just build artifacts, not deployables), and move the **only** real,
  deployable, per-environment-URL-baked-in PWA build into `release-deploy.yml`
  (tagged with the release version, `-rc` or not, same as the Go services) — this
  is probably the more consistent design given the new plan, but wasn't decided
  before this session ended.
- (b) Keep both paths as-is (redundant, more moving parts, not recommended).

**Recommendation for next session: go with (a)** — simplifies the mental model to
"CI validates on every PR, `release-deploy.yml` is the only thing that produces a
real deployable artifact, for any component, in any environment."

### 4.4 Open question: separate GitOps repo

Decided (see conversation): **yes**, split `infra/gitops/` out into its own new
repo (e.g. `beekeepingit-gitops`) — no credential-cost to this now that the
mechanism is PR-based (not direct-push), so it's a pure structural/hygiene choice,
not a security trade-off. Concretely:

- New repo holds everything currently under `infra/gitops/` — the
  `HelmRelease`/`GitRepository`/`Kustomization` objects, per-environment
  overrides.
- **This repo** (`beekeepingit`) keeps `infra/helm/beekeepingit/` (the actual Helm
  chart — templates, subcharts). Flux supports sourcing the chart from one
  `GitRepository` while the `HelmRelease` object (and its values) live in and are
  reconciled from a different one — this is a normal, supported split, not a hack.
- Each cluster's `flux-system.yaml` `GitRepository.spec.url` moves to point at the
  new repo. The `HelmRelease.chart.spec.sourceRef` continues pointing at _this_
  repo for the chart itself.
- `release-deploy.yml` (which lives here, since this is where releases get cut)
  opens its tag-bump PR against the **new** repo, not this one — needs a token
  with access to that repo (a fine-grained PAT or, cleaner, a small GitHub App
  installed on both repos — decide at build time; a same-org token can often reach
  both repos already if using `GITHUB_TOKEN` won't, so check whether a token is
  even needed before reaching for a PAT).

**Not started** — this is real restructuring work (moving `infra/gitops/`, standing
up the new repo, rewiring every `GitRepository`/`HelmRelease` reference across
`infra/cluster/scaleway-up.sh`'s bootstrap instructions and any docs that reference
paths under `infra/gitops/`), bigger than anything else in this plan. Good moment
to do it though — before more accumulates there.

## 5. New plan: real domain (`melargil.pt`) instead of nip.io

User owns **`melargil.pt`** (registrar: LusoAloja; DNS/nameservers: **Cloudflare**
— so all DNS record management happens in the Cloudflare dashboard/API, not
LusoAloja). Goal: real subdomains instead of the nip.io placeholder used so far.

User's proposed names: `beekeepingit.melargil.pt` and `beekeeping-rc.melargil.pt`
— **note the inconsistency** (`beekeepingit` vs `beekeeping-rc`, missing the `it`)
— confirm exact naming with the user before creating records; this plan assumes
it's intentional shorthand but flags it rather than silently "fixing" it.

**Important, not yet accounted for in the user's ask**: per ADR-0016 (cross-origin
isolation for PowerSync's `SharedArrayBuffer`), **each environment needs two
hostnames, not one** — an app host and a separate auth host (`gateway.appHost`/
`gateway.authHost`, currently `app.51-159-204-90.nip.io`/`auth.51-159-204-90.nip.io`
for staging). So the real scheme needs 4 hostnames total once both environments
are live, e.g. (naming TBD with user):

| Environment | App host                         | Auth host                             |
| ----------- | -------------------------------- | ------------------------------------- |
| prod        | `beekeepingit.melargil.pt`      | `auth.beekeepingit.melargil.pt` (?)  |
| staging/rc  | `beekeeping-rc.melargil.pt` (?) | `auth.beekeeping-rc.melargil.pt` (?) |

### Steps for next session

1. **Confirm exact subdomain naming** with the user (the inconsistency above, and
   the auth-host names, which weren't specified).
2. **Get (or reuse) a Scaleway reserved/static IP per environment**, attached to
   each cluster's Traefik LoadBalancer, instead of relying on the LB's
   auto-assigned ephemeral IP. Relevant because this project already tears
   clusters down to save cost (§1) and brings them back up later — recreating the
   cluster recreates the LoadBalancer Service, which risks a **different** IP each
   time (not confirmed either way this session — the IP happened to stay stable
   across the one resize done, but that shouldn't be relied on). A reserved IP
   survives cluster teardown/recreate, so DNS records don't need updating every
   time. Check Scaleway's reserved-IP-for-Kapsule-LoadBalancer mechanism
   (annotation-based, typically) before deciding cluster bring-up needs no change
   vs. does.
3. **Create the DNS records in Cloudflare** — A records for all 4 (eventually)
   hostnames, pointing at the relevant reserved IP. Recommend **DNS-only (grey
   cloud), not proxied (orange cloud)** for these specific records — Cloudflare's
   proxy can complicate ACME HTTP-01 challenges, and there's no clear benefit
   (WAF/caching/DDoS protection) for a small internal-ish app at this stage. Can
   be done manually via the Cloudflare dashboard (simplest, no new credential) or
   automated via the Cloudflare API (needs a scoped API token — only worth it if
   this needs to be repeatable/scripted, e.g. if reserved IPs turn out not to be
   available and the IP genuinely changes on every cluster recreate).
4. **Decide HTTP-01 vs DNS-01 for cert-manager.** Currently HTTP-01 (already
   proven working end-to-end against nip.io) — still works fine against a real
   domain, no change needed, **unless** step 3 ends up using Cloudflare's proxy
   (which would break HTTP-01) or a wildcard cert becomes desirable (DNS-01
   supports wildcards, HTTP-01 doesn't) — DNS-01 needs a Cloudflare API token
   scoped to DNS-edit on just the `melargil.pt` zone, stored as a cert-manager
   Secret. Default to keeping HTTP-01 unless a concrete reason to switch comes up.
5. **Update values once DNS is live**: `global.appOrigin`, `gateway.appHost`/
   `authHost`, `services.oidc.issuerUrl` in `environments/staging.yaml` (and
   `apps/staging/beekeepingit-helmrelease.yaml`, or their new-repo equivalents per
   §4.4) — swap the nip.io values for the real ones. Same fields, just new values;
   nothing structural changes (this exact swap was already anticipated in the
   nip.io commit's own comments).

## 6. Suggested order for the next session

1. Remove the dead Flux image-automation objects (§3) — quick, low-risk, clears
   the way for the rest.
2. Stand up the new GitOps repo and move `infra/gitops/` (§4.4) — biggest,
   highest-value structural piece, do it before more accumulates in the old
   location.
3. Rework `release-deploy.yml` with the `-rc` branching + PR-opening step (§4.2),
   pointed at the new repo.
4. Resolve §4.3 (PWA build path) — recommend option (a).
5. Confirm DNS naming with the user, then execute §5's steps.
6. Bring the staging cluster back up (`scaleway-up.sh`), verify the whole chain
   end-to-end: cut a `v0.0.1-rc1` release → image builds → PR opens → merge → Flux
   deploys → real domain resolves with a trusted cert → login works.
