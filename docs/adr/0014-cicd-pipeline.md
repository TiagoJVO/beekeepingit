# 0014 — CI/CD: path-filtered monorepo pipeline (build/scan/publish + GitOps image-automation)

- **Status:** Accepted
- **Date:** 2026-07-05
- **Issue / Epic:** #88 / EPIC-13 (#14) · **Milestone:** M0
- **Requirements:** NFR-TST-1, NFR-MNT-1, NFR-ARC-3 · **Decisions:** D-9 (monorepo), D-10 (rollout)
- **Tech choice:** [`requirements/tech-stack.md`](../../requirements/tech-stack.md) — "CI/CD:
  GitHub Actions" (status "Proposed" — this ADR is its as-built record)
- **Design:** [`docs/architecture/platform.md#cicd`](../architecture/platform.md#cicd)

## Context

EPIC-13 calls for a **path-filtered monorepo** (D-9) CI/CD pipeline: per-affected-component
lint → test → build, dependency + container-image scanning that fails on severity, image publish
to a registry tagged by commit, and deploy via the GitOps flow — never manual `kubectl`. Its
blockers are both merged: #19 (the `task` runner + per-language discovery) and #86 (Flux GitOps).

The defining constraint is that **nothing is container-buildable yet**: no service has a
`Dockerfile` or `main.go`, there is no client or admin app, and `services/shared` is a library.
So — exactly as with [`ci.yml`](../../.github/workflows/ci.yml) and the taskfiles before it — the
pipeline is built as a **ready-but-dormant framework that self-discovers components and no-ops
until code lands** ("green before code", D-9). The scanning tooling and severity policy are the
mechanism EPIC-14 #89 shares and tunes; this story wires the stages.

## Decision

1. **Two new workflows, splitting concerns like the existing `helm-ci.yml`/`gitops-ci.yml`:**
   - [`security-scan.yml`](../../.github/workflows/security-scan.yml) — repo-level supply-chain
     scanning on every PR/push: **Trivy `fs`** (dependency + secret, **blocking** on
     HIGH,CRITICAL, `ignore-unfixed`), **`govulncheck`** across every Go module (via `task go:vuln`,
     the same discover-and-no-op pattern as the other Go targets), and **Trivy `config`** (IaC
     misconfig) run **report-only** for now.
   - [`build-publish.yml`](../../.github/workflows/build-publish.yml) — a `detect` job diffs the
     change and emits a **matrix of only the changed directories that contain a `Dockerfile`**
     (path filtering + self-discovery, empty today ⇒ the build job skips). The build job runs
     lint/test → builds the image → **Trivy image scan** (blocking) → on merge to `main`, pushes
     to **ghcr.io** tagged by commit.

2. **Registry: ghcr.io.** Native to GitHub Actions via `GITHUB_TOKEN` (no extra account or secret),
   free for this single-org project. Images are `ghcr.io/<owner>/beekeepingit/<component>`.

3. **Scanner: Trivy** (+ `govulncheck` for Go's call-graph-aware DB). One tool covers dependency,
   container-image, secret, and IaC scanning with a single severity gate — the shared mechanism
   #89 configures. `govulncheck` complements Trivy's SBOM scan with reachability analysis.

4. **Deploy via Flux image-automation, not CI-commits-to-Git.** CI only publishes; the
   image-reflector + image-automation controllers watch the registry and commit the new tag into
   Git, which Flux then reconciles — the purest GitOps split (extends the #86 Flux install with
   `--components-extra`). The engine + per-service templates live in
   [`infra/gitops/image-automation/`](../../infra/gitops/image-automation/), **dormant** (outside
   the reconciled Kustomization paths) until the first service publishes an image and a Git
   write-credential (an EPIC-14 #89 secrets task) is provisioned. Main images carry an extra
   `<YYYYMMDDHHMMSS>-<sha>` tag because commit SHAs are not chronologically orderable — the
   `ImagePolicy` selects the newest build by that timestamp.

5. **macOS/iOS CI is explicitly deferred to M5 / EPIC-15** (D-10: PWA → Android → iOS, native only
   when needed) — recorded as a disabled `ios-build` placeholder job in `build-publish.yml`.

## Consequences

- The pipeline is **green today with zero components to build**: the build matrix is empty, so
  `build-publish.yml` skips; `security-scan.yml` runs against `services/shared` and passes. It
  activates automatically the day a directory gains a `Dockerfile` — no workflow edit needed.
- **Not exercised end-to-end yet.** A real publish → tag-bump → reconcile can only be proven once a
  service ships an image (and the Git write-secret exists). The activation steps are documented in
  [`infra/gitops/image-automation/README.md`](../../infra/gitops/image-automation/README.md) and
  tracked in [`FOLLOWUPS.md`](../../FOLLOWUPS.md); this is the honest dormant boundary.
- **Trivy `config` is report-only** so pre-existing Helm/k8s baseline findings don't fail unrelated
  PRs; #89 triages the baseline then flips it to blocking. Dependency + image scanning are blocking
  now, satisfying the AC.
- Dependabot gains a `gomod` ecosystem (`services/shared`) alongside `github-actions`; `docker`/
  `npm`/`pub` are added as those packages land.
- `ci.yml` still runs the repo-wide lint+test safety net; per-component lint/test moves into the
  build matrix as services add scoped `task` targets (its own comment already anticipated this).

## Alternatives considered

- **CI commits the image tag to Git** (instead of Flux image-automation) — rejected: gives CI write
  access to `main` and splits the deploy path between CI and Flux. Image-automation keeps deploy
  wholly inside GitOps; the cost is two extra controllers, which are cheap.
- **Docker Hub / self-hosted registry** — rejected: Docker Hub needs a PAT secret and has pull
  rate limits; a self-hosted registry is infra to stand up and secure for no M0 benefit over ghcr.
- **Grype+Syft or GitHub-native (CodeQL/Dependabot only)** — rejected: two tools without built-in
  IaC scanning, or no container-image scanning at all (which the AC requires).
- **Waiting for the first service before landing #88** — rejected: the framework is the
  deliverable, and building it now (dormant) unblocks every downstream service story from having to
  invent its own CI, exactly as `ci.yml`/`helm-ci.yml` did.
