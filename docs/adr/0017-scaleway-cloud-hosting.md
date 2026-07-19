# 0017 — Cloud hosting: Scaleway Kapsule, staging stood up first

- **Status:** Accepted
- **Date:** 2026-07-18
- **Requirements:** NFR-ARC-2, NFR-ARC-3, NFR-CMP-1
- **Decisions:** [D-26](../../requirements/decisions.md) (hosting provider choice), builds on
  [D-1](../../requirements/decisions.md) (single cluster), [D-13](../../requirements/decisions.md)
  (GitOps: Flux)
- **Design:** [`infra/README.md`](../../infra/README.md), [`infra/gitops/README.md`](../../infra/gitops/README.md)

## Context

Everything under `infra/` had only ever run on a local k3d cluster. D-26 chose **Scaleway
Kapsule** as the cloud provider (see `decisions.md` for the cost/EU-region comparison against
Hetzner/OVHcloud/hyperscalers). This ADR records what stood the first real cluster up and the
bugs that only a genuinely fresh, from-scratch cloud deployment surfaced — several of which were
latent in the existing Helm/GitOps layout regardless of provider, just never exercised.

## Decision

### 1. `infra/cluster/scaleway-up.sh`/`scaleway-down.sh`, mirroring `up.sh`/`down.sh`'s shape

Idempotent bring-up/teardown for a `beekeepingit-staging` Kapsule cluster, installing the same
cluster-scoped prerequisites `up.sh` gets from k3d for free: CloudNativePG operator, an ingress
controller (Traefik — Kapsule doesn't bundle one), cert-manager, and Flux controllers. Two
portability fixes needed for Windows/Git Bash specifically: `flock` (used for the same-machine
concurrency lock `up.sh` also uses) isn't bundled with Git Bash, so it's now optional, not
required; and the k8s version is looked up at runtime (`scw k8s version list`) instead of pinned,
since Kapsule only supports the last ~3 minor releases (~12 months each) and a hardcoded constant
would eventually request a rejected version.

Default node type is `DEV1-L` (4vCPU/8GB), not the cheaper `DEV1-M` (3vCPU/4GB) it started on —
confirmed via `kubectl top node` that the full stack's memory requests alone hit ~90% of `DEV1-M`'s
allocatable, leaving no room for one-off Jobs (Authentik's blueprint-apply worker, MinIO's
bucket-creation hook) to even schedule.

### 2. GitOps layout mirrors `dev` exactly — `clusters/staging/`, `apps/staging/`

Same pattern as `clusters/dev/`/`apps/dev/` (ADR-0009): a `GitRepository` + self-referential
`Kustomization` bootstrap, plus the umbrella `HelmRelease` and the standalone Authentik/MinIO
`HelmRelease`s (ADR-0012). `prod` gets the identical scaffold prepared alongside staging's (see
`clusters/prod/`, `apps/prod/`) — not deployed anywhere (D-26 defers a real prod environment until
`Q-DR` and `#90` land at M6), but built with every fix below already in place so its eventual
bring-up doesn't rediscover them.

### 3. Real bugs a from-scratch cloud install surfaced (fixed here, not provider-specific)

- **Helm install hook deadlock.** `install.disableWait`/`upgrade.disableWait` added to the
  `beekeepingit` `HelmRelease` (both `staging` and `dev`, the latter just never exercised it — see
  its own comment). Helm's default wait-for-ready gates every Deployment before an install is
  considered successful, but `charts/postgres/templates/schema-grants-job.yaml` — a post-install
  hook every DB-backed service and PowerSync depend on — only runs _after_ that wait succeeds. A
  true from-scratch install can never converge. `dev`'s Flux `HelmRelease` never hit this because
  it's only ever _upgraded_ a release originally bootstrapped by a manual `helm install` (no
  `--wait` by default on the raw CLI), which sidesteps the deadlock entirely.
- **`NetworkPolicy` gateway-namespace mismatch.** Every gateway-to-backend edge in
  `charts/networkpolicy/values.yaml` hardcoded `namespaceSelector: kube-system` — correct for
  k3d/dev (Traefik's default namespace there), wrong for this cluster, which installs Traefik into
  its own `traefik` namespace. Silently blocked all Traefik→backend ingress, not just
  cert-manager's dynamically-created ACME solver pods (which additionally had no edge at all).
  Now a `gatewayNamespace` value (sentinel-substituted in the one template that needs it, since
  `values.yaml` isn't itself template-rendered), defaulting to `kube-system`.
- **Authentik blueprint's redirect_uris were dev-hardcoded.** The OAuth2 provider's
  `redirect_uris`/CORS-allowed-origins were a static file (`.Files.Get` never processes `{{ }}`),
  hardcoded to `app.beekeepingit.local:8443`. Login failed everywhere else with a redirect_uri
  mismatch. Now rendered through `tpl`, parameterized by a new shared `global.appOrigin` value.

### 4. TLS: `nip.io` + cert-manager, not a real domain (yet)

No domain is owned yet. Staging uses `nip.io` (free wildcard DNS resolving `<name>.<ip>.nip.io` to
that literal IP, no registration) for real, publicly-resolvable hostnames — works from any device,
and lets Let's Encrypt's HTTP-01 challenge issue a genuinely trusted cert via a new
`charts/gateway/` `certManager.enabled` toggle (mutually exclusive with the existing self-signed
cert template) and a cluster-scoped `ClusterIssuer`. Swapping to a real domain later is a values
change (`global.appOrigin`, `gateway.appHost`/`authHost`), nothing structural.

### 5. PWA image: a known gap, not fully closed here

The PWA's OIDC/gateway/PowerSync URLs are Dart **compile-time** constants
(`client/lib/core/config/app_config.dart`, `--dart-define`) — unlike every other component here,
which reads config from runtime env vars. CI never passed any `--dart-define`s, so the single
published `latest` image only ever had dev's URLs baked in. `build-publish.yml`'s `detect` job now
builds a distinct tagged variant per environment (`client-dev`, `client-staging`) instead of one —
closes the immediate gap, but the PWA still can't do "build once, promote the same artifact across
environments" the way the Go services can; see `FOLLOWUPS.md` for that longer-term option.

## Consequences

- Standing up a second cloud environment (or rebuilding this one) should no longer hit any of the
  bugs in §3 — they were latent in the shared chart/GitOps layout, not staging-specific.
- The `gatewayNamespace` and `certManager.enabled` values are now genuine per-environment knobs;
  `environments/staging.yaml`/`environments/prod.yaml` demonstrate the pattern.
- `prod`'s GitOps scaffold exists in Git but is inert — nothing bootstraps against it without a
  real cluster + `kubectl apply`, same as `staging` before this ADR.

## Alternatives considered

See `decisions.md`'s `D-26` entry for the provider comparison (Hetzner, OVHcloud, DigitalOcean,
hyperscalers) — out of scope for this ADR, which covers the _implementation_ once Scaleway was
chosen.
