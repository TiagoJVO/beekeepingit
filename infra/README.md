# Infrastructure

The single-cluster Kubernetes platform (`NFR-ARC-3`) and the Helm umbrella chart that deploys
it (`NFR-ARC-1`, `D-1`). See [`docs/architecture/platform.md`](../docs/architecture/platform.md)
for the as-built design; intent/decisions live in
[`requirements/decisions.md`](../requirements/decisions.md) and
[`requirements/tech-stack.md`](../requirements/tech-stack.md).

## Quickstart

A single command brings up the whole local dev environment (`#22`, `NFR-ARC-2`/`NFR-ARC-3`) —
Postgres+PostGIS, Authentik, PowerSync, MinIO, and the gateway/ingress — and another tears it down:

```sh
infra/cluster/dev-up.sh    # idempotent: safe to re-run against an already-provisioned cluster
infra/cluster/dev-down.sh  # uninstalls the releases, then deletes the k3d cluster
```

Requires `k3d`, `kubectl`, `helm`, `flux`, and `flock` on `PATH`. On Windows, run these from the
WSL2 environment (see the local-dev-environment notes) — the scripts are plain POSIX `bash`.

`dev-up.sh` does NOT bootstrap GitOps (apply the `beekeepingit-gitops` repo's `clusters/dev/`, the
one-time wiring that makes Flux auto-sync from `main`) — that would deploy the umbrella chart from
`main`, ignoring whatever's checked out locally, the opposite of what a pre-merge dev/test loop
needs. It also skips the observability stack (`#87`) — not one of `#22`'s components, and its
HelmRelease depends on that same bootstrap `GitRepository`. The Flux manifests live in the separate
[`beekeepingit-gitops`](https://github.com/TiagoJVO/beekeepingit-gitops) repo now (D-27/ADR-0018);
see its README for the post-merge bootstrap step.

### Step-by-step (what `dev-up.sh`/`dev-down.sh` actually do)

```sh
# 1. Bring up the local cluster (k3d, idempotent) — also installs/upgrades the
#    CloudNativePG operator, a cluster-scoped prerequisite for the `postgres`
#    subchart (see charts/postgres/Chart.yaml and ADR-0010)
infra/cluster/up.sh

# 2. Install/upgrade the Flux controllers (idempotent) — authentik/minio below are
#    Flux HelmReleases, so this is a real prerequisite, not optional. Base
#    controllers only: Flux is read-only (D-27/ADR-0018 dropped image-automation).
flux install

# 3. Fetch chart dependencies (local + vendored third-party, see the chart's README) —
#    re-run after cloning, after changing a dependency version, AND after editing any
#    local subchart's templates/values (helm installs the packaged charts/*.tgz
#    snapshot under this dir, not the live source — a stale snapshot silently
#    installs old content otherwise, see FOLLOWUPS.md).
helm dependency build infra/helm/beekeepingit

# 4. Install (or upgrade) the platform. Deliberately no `--wait`: PowerSync can't
#    pass its readiness probe until the postgres subchart's schema-grants Job (a
#    post-install hook, since the `powersync` role doesn't exist yet at install
#    time) has granted it access to `powersync_storage` — and Helm only runs
#    post-install hooks *after* `--wait` is satisfied for the main resources, so
#    waiting here would deadlock PowerSync against its own grant.
infra/cluster/with-lock.sh helm upgrade --install beekeepingit infra/helm/beekeepingit \
  -f infra/helm/beekeepingit/environments/dev.yaml \
  --namespace beekeepingit-dev --create-namespace

# 5. Wait for postgres explicitly instead (see step 4's note). `dev-up.sh`'s
#    actual `wait_for_pod` helper polls until a matching pod exists before this
#    call — `kubectl wait` errors immediately ("no matching resources found")
#    rather than waiting, if the Deployment/StatefulSet/HelmRelease that owns
#    the pod hasn't created it yet:
kubectl -n beekeepingit-dev wait --for=condition=ready pod \
  -l cnpg.io/cluster=beekeepingit-postgres --timeout=180s

# 6. Authentik/MinIO are separate Flux HelmReleases (ADR-0012/ADR-0016), not part
#    of the umbrella release above, and their manifests live in the beekeepingit-gitops
#    repo now (D-27/ADR-0018). dev-up.sh resolves a checkout via gitops-dir.sh (a
#    shallow clone, or a BEEKEEPINGIT_GITOPS_DIR override); apply them directly for
#    local-only testing. Their `dependsOn: [beekeepingit]` targets a HelmRelease
#    *object* that only exists once bootstrapped, so strip it for this direct-apply
#    path (committed files untouched) — step 4's install already guarantees what
#    dependsOn was protecting (the config/Postgres Secrets + blueprint ConfigMap
#    these reference are created synchronously when the release's resources are
#    applied, independent of `--wait`):
gitops_dir="$(infra/cluster/gitops-dir.sh)"
for f in authentik-helmrelease.yaml minio-helmrelease.yaml; do
  sed '/^  dependsOn:$/,+1d' "$gitops_dir/apps/dev/$f" \
    | infra/cluster/with-lock.sh kubectl apply -f -
done

# 7. Wait for the PowerSync rollout (now unblocked by the schema-grants hook above)
kubectl -n beekeepingit-dev rollout status deployment/beekeepingit-powersync --timeout=180s

# 8. Wait for Authentik/MinIO (see step 5's note on the pod-exists-first race), then
#    smoke-test the backing services (Postgres/PostGIS; #84). Authentik + its bundled
#    Postgres takes a few minutes to boot (bootstrap migrations + blueprint apply), so
#    allow more time. MinIO's vendored chart predates the app.kubernetes.io/* label
#    convention — it only sets the legacy app=minio,release=<release-name> labels.
kubectl -n beekeepingit-dev wait --for=condition=ready pod -l app.kubernetes.io/instance=authentik --timeout=420s
kubectl -n beekeepingit-dev rollout status deployment/authentik-server --timeout=420s
kubectl -n beekeepingit-dev wait --for=condition=ready pod -l app=minio,release=minio --timeout=180s
helm test beekeepingit --namespace beekeepingit-dev

# 9. Tear down
infra/cluster/with-lock.sh kubectl delete --ignore-not-found \
  -f "$gitops_dir/apps/dev/authentik-helmrelease.yaml" \
  -f "$gitops_dir/apps/dev/minio-helmrelease.yaml"
infra/cluster/with-lock.sh helm uninstall beekeepingit --namespace beekeepingit-dev
infra/cluster/down.sh
```

## Verify the environment

Each of `#22`'s acceptance checks, in one place (all assume `dev-up.sh` finished successfully):

```sh
# PostGIS is enabled (helm test already runs this; shown here standalone)
kubectl -n beekeepingit-dev exec beekeepingit-postgres-1 -- \
  psql -U postgres -d beekeepingit -c "SELECT postgis_version();"

# Authentik: seeded OIDC provider's discovery doc reachable through the gateway on
# the dedicated auth host (add app.beekeepingit.local, auth.beekeepingit.local AND
# admin.beekeepingit.local — the admin app's host, #449 — to /etc/hosts pointing at
# 127.0.0.1, or use --resolve like this). The issuer is
# https://auth.beekeepingit.local:8443/application/o/beekeepingit/ (oidc-integration.md §6).
curl -sk --resolve auth.beekeepingit.local:8443:127.0.0.1 \
  https://auth.beekeepingit.local:8443/application/o/beekeepingit/.well-known/openid-configuration

# MinIO: reachable via an S3-compatible client (health endpoint shown here; `mc`/`aws s3`
# work the same way once port-forwarded)
kubectl -n beekeepingit-dev port-forward svc/minio 9000:9000 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/minio/health/live

# PowerSync: pod healthy, replication + storage connected, no JWKS-fetch errors
kubectl -n beekeepingit-dev get pods -l app.kubernetes.io/name=powersync
kubectl -n beekeepingit-dev logs -l app.kubernetes.io/name=powersync --tail=50

# Gateway: routes to backend services on three hosts (ADR-0016, #449) — the auth host
# to Authentik (the curl above exercises this), the app host to the PWA + Go APIs
# (/v1/*) + PowerSync (/sync-stream), and the admin host to the React admin app.
# The admin app is cross-origin from the app-host API, so the Go services answer its
# browser CORS (Access-Control-Expose-Headers: ETag) via the servicetemplate CORS
# middleware — origins set per environment (global.adminOrigin).
```

PowerSync's real org-scoped Sync Rules + the `sync`-service JWKS connector landed with
`#23`/`#106` (the `#22` placeholder sync-config + OIDC-JWKS stopgap are gone) — see
`FOLLOWUPS.md` for any remaining wiring.

## Sharing the local cluster across concurrent sessions

The local `beekeeping` k3d cluster is one shared, mutable resource — if two sessions (e.g. two
concurrent Claude Code agents in different git worktrees) run `infra/cluster/up.sh`/`down.sh` or
`helm install/upgrade/uninstall` against it at the same time, they can race: one tearing down the
cluster (or a release) while the other is mid-operation, causing exactly the kind of node/pod
churn that looks like environment flakiness but is actually a collision.

`up.sh`/`down.sh` take a `flock`-based lock on `/tmp/k3d-beekeeping.lock` themselves, so they
serialize automatically against each other (from any worktree — the lock is keyed by the cluster
name, not by path, since different worktrees are different directories on disk but the same
lockfile path is shared across all of them within one WSL2 instance). For anything else that
mutates the cluster — `helm install`/`upgrade`/`uninstall`, ad-hoc `kubectl apply` — wrap it with
[`infra/cluster/with-lock.sh`](cluster/with-lock.sh), which takes the same lock:

```sh
infra/cluster/with-lock.sh helm install beekeepingit infra/helm/beekeepingit -f ...
```

Read-only commands (`kubectl get`, `helm test`, `helm lint`/`template`) don't need the lock.

This is a **local-dev-only** convention — it has no bearing on CI. Live-cluster CI does exist
(`.github/workflows/helm-e2e.yml`, `#154`, which even runs `up.sh`/`down.sh` themselves), but each
GitHub-hosted runner is a fresh, isolated machine that shares no filesystem with this one or with
other concurrent runs, so the `flock` serialization simply no-ops there — the lock protects the one
shared local cluster, and CI has no such shared resource to protect.

## Secrets & remote cluster operations

**In-cluster secrets provision themselves.** Every secret the platform needs at runtime —
per-service Postgres credentials, PowerSync credentials, Authentik's secret key/bootstrap
identity/DB password, MinIO root credentials — is generated _inside_ the cluster by the umbrella
chart (Helm `lookup` + `randAlphaNum`, preserved across upgrades; `NFR-SEC`). They are never
stored in git, GitHub, or on disk, and no bring-up script needs to supply them. The one
out-of-band exception is `beekeepingit-authentik-email-credentials` (an external SMTP relay's
credentials, #361), which `scaleway-up.sh` creates when the variables below are set.

**External credentials are plain environment variables, sourced from two places:**

- **Local runs**: `infra/cluster/.env` (gitignored), loaded by every `infra/cluster` script via
  `env.sh` — copy [`.env.example`](cluster/.env.example) and fill in what you need. Values already
  exported in your shell win over the file.
- **GitHub Actions**: the same variable names, injected from GitHub secrets/variables by
  [`cluster-ops.yml`](../.github/workflows/cluster-ops.yml). GitHub secrets are **write-only** — a
  local run cannot read them back — which is why the `.env` file exists at all. Treat GitHub as
  the canonical store; the `.env` file is a local working copy.

| Name                                                     | Kind                     | Used for                                                           |
| -------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------ |
| `SCW_ACCESS_KEY` / `SCW_SECRET_KEY`                      | environment secret       | Scaleway API auth (`scaleway-up.sh`/`scaleway-down.sh`)            |
| `SCW_DEFAULT_PROJECT_ID` / `SCW_DEFAULT_ORGANIZATION_ID` | environment secret       | Scaleway project/org scoping                                       |
| `CF_API_TOKEN` / `CF_ZONE_ID`                            | environment secret       | Cloudflare dynamic DNS on bring-up (optional)                      |
| `AUTHENTIK_EMAIL_USERNAME` / `AUTHENTIK_EMAIL_PASSWORD`  | environment secret       | out-of-band SMTP relay Secret (optional, #361)                     |
| `APP_HOST` / `AUTH_HOST`                                 | environment **variable** | per-environment public hostnames (scoped to each gate environment) |

Store the secrets **scoped to the gate environments** (`staging-gate`/`production-gate`), not
repo-wide: the workflow's `run` job carries the gate environment, so environment secrets resolve
first — and the ungated staging path then never holds prod-capable credentials. Ideally issue a
separate, IAM-restricted Scaleway API key per environment. (Repo-level secrets also work as a
single-maintainer fallback, at the cost of that separation.) Create them once (manual — an agent
must not handle the values):

```sh
gh secret set SCW_ACCESS_KEY --env staging-gate    # paste when prompted; repeat for the others
gh variable set APP_HOST --env staging-gate --body beekeepingit-rc.melargil.pt
gh variable set AUTH_HOST --env staging-gate --body auth.beekeepingit-rc.melargil.pt
```

(The `staging-gate`/`production-gate` environments are D-27's release-approval gates; create one
under _Settings → Environments_ first if it doesn't exist yet.)

**On-demand runs from GitHub**: the [`cluster-ops.yml`](../.github/workflows/cluster-ops.yml)
`workflow_dispatch` workflow runs one of the four scripts below with those secrets — pick
`environment` (staging/prod) and `action` (up/down/scale-down/scale-up) in the Actions tab. Staging
runs immediately; prod waits for `production-gate`'s required reviewer on **every** action; `down`
additionally requires typing the exact cluster name into the `confirm` input, since it permanently
deletes a real, billed cluster. Note the D-26 scope guard: bringing up the prod _cluster_ is fine
(it holds no user data), but deployments stay staging-grade until DR (`Q-DR`) and GDPR
export/erasure (#90) land.

### Pausing and resuming an environment without losing data (#539)

Tearing an environment down with `scaleway-down.sh` is a **permanent, destructive** operation — it
deletes the cluster, its node pool, its block-storage volumes, and its Load Balancers
(`with-additional-resources=true`), so a subsequent `scaleway-up.sh` always starts from a genuinely
empty state (`bootstrap.initdb`, fresh Authentik/MinIO). That's the right tool when you actually
want to throw an environment away, but it's the wrong default for "I'm done for today, stop the
meter until tomorrow" — routinely destroying and re-provisioning an environment for that is not a
restart, it's a repeated data-loss event.

**`scaleway-scale-down.sh`/`scaleway-scale-up.sh` are the routine pause/resume pair instead.**
Rather than deleting the cluster, `scale-down` deletes the environment's LoadBalancer-type
Service(s) (so Scaleway's cloud-controller-manager cleanly deprovisions the billed Load Balancer
behind them through its own reconciliation, instead of the script calling the Scaleway API directly
against a Service the CCM still believes it owns) and scales the node pool to **0**. The
**cluster itself — its control plane, its etcd, and therefore every `PersistentVolumeClaim`,
`PersistentVolume`, and the CNPG `Cluster` custom resource — stays alive.** `scale-up` scales the
pool back up and reinstalls the cluster-scoped prerequisites that lived on the deleted nodes (CNPG
operator, Traefik — which provisions a fresh Load Balancer — cert-manager, Flux); CNPG Postgres,
Authentik, and MinIO reschedule onto the new nodes and reattach their already-`Bound` PVCs through
completely standard Kubernetes CSI semantics. **There is no volume-reattachment logic anywhere in
this design, because nothing is ever detached from the cluster's object model** — only from its
compute. `scale-up` fails with a clear error (rather than silently creating a new cluster) if the
target cluster doesn't exist at all — it resumes a paused environment, it doesn't create one.

This works because Kapsule's control plane is **free on the default "Mutualized" tier, independent
of node count** (confirmed on Scaleway's pricing page) — a cluster scaled to 0 nodes costs nothing
beyond its still-attached block-storage volumes, which you're paying for either way if you want the
data kept. `scale-down` does **not** require the `confirm` input `down` does: it destroys nothing.

Two things this design does **not** have a documented answer for, so don't treat them as settled:

- **Control-plane tier.** This only holds if the cluster is on the Mutualized tier, not a paid
  Dedicated one (`scw k8s cluster get <id> region=<region>` → check `.Type`). Confirm this once per
  cluster if you're not sure how it was created.
- **Long-idle zero-node clusters.** Scaleway's docs don't state a policy either way on reaping
  clusters left at 0 nodes for extended periods. Don't rely on `scale-down` for multi-week/-month
  pauses without checking directly with Scaleway first — for that horizon, `scaleway-down.sh` (full
  teardown) is the safer, better-understood choice.

| Script                   | Effect                                                          | Data          |
| ------------------------ | --------------------------------------------------------------- | ------------- |
| `scaleway-up.sh`         | create the cluster (or reconcile an existing one)               | n/a (fresh)   |
| `scaleway-down.sh`       | **permanently destroy** the cluster + volumes + Load Balancers  | **destroyed** |
| `scaleway-scale-down.sh` | scale the node pool to 0; cluster/control plane keep running    | **kept**      |
| `scaleway-scale-up.sh`   | scale the node pool back up; fails if the cluster doesn't exist | **kept**      |

### Enabling "Continue with Google" on an environment (#363)

Google federation is **off unless its credentials exist in the cluster** — the blueprint entry is
condition-gated on them, so an environment without them deploys cleanly with no Google button and
no outbound call to Google at blueprint-apply time (see
[`docs/architecture/auth.md`](../docs/architecture/auth.md) §8.13 for why that gate is
load-bearing). Turning it on is three steps, none of which put a secret in git.

1. **Create the OAuth client** in [Google Cloud Console](https://console.cloud.google.com/) →
   _APIs & Services → Credentials → Create credentials → OAuth client ID_, application type **Web
   application**. Configure the OAuth consent screen first if the project has none.
2. **Add the redirect URI exactly as Authentik builds it** — trailing slash included, because
   Authentik reverses the same URL when it sends the user out _and_ when it rebuilds it for the
   token exchange; a mismatch fails the exchange with `redirect_uri_mismatch`:

   ```text
   https://<AUTH_HOST>/source/oauth/callback/google/
   ```

   e.g. `https://auth.beekeepingit-rc.melargil.pt/source/oauth/callback/google/`. The slug
   (`google`) is the source's slug in the blueprint — change one and you change both.

3. **Create the out-of-band Secret** in the target namespace (manual — an agent must not handle
   these values). This is the same cluster-state-not-git idiom as the SMTP relay credentials
   above; the chart merges it into `beekeepingit-authentik-config` via `lookup`, and the upstream
   Authentik chart env-mounts it onto the server and worker:

   ```sh
   kubectl -n <namespace> create secret generic beekeepingit-authentik-google-credentials \
     --from-literal=client-id='<the OAuth client id>' \
     --from-literal=client-secret='<the OAuth client secret>'
   ```

   Then re-run the umbrella `helm upgrade` for that environment — the `lookup` only sees the
   Secret on a subsequent render — and let the Authentik worker re-apply the blueprint. Verify
   with `kubectl -n <namespace> get secret beekeepingit-authentik-config -o jsonpath='{.data}' |
grep -o BEEKEEPINGIT_GOOGLE_CLIENT_ID` and by loading the login page: a **Continue with
   Google** button appears on Authentik's own login card.

   Enabling this in the **dev** namespace leaves the dev/CI federation stand-in enabled too
   (`environments/dev.yaml`); the blueprint binds **both** buttons onto the login card in that
   case, so seeing two is expected, not a misconfiguration.

   To turn it off again, delete the Secret and re-run `helm upgrade`: the next render drops the
   env, the blueprint's condition goes false, and the unconditional identification-stage entry
   resets `sources: []` so the button disappears. The `OAuthSource` row itself is left behind
   (blueprints don't delete) — remove it in the Authentik admin UI if you want it gone entirely.

**Manual verification checklist (required once per environment).** CI proves the config, the deny
posture and everything up to the outbound request, but **nothing automated completes a sign-in
through a real Google account** — a live e2e against Google is not automatable (consent screen +
bot detection). Run this by hand after step 3, and record the result on the PR/issue:

- [ ] The app's **Continue with Google** button goes straight to Google's consent screen — one
      hop, no stop at Authentik's login form.
- [ ] Signing in with a Google account whose address matches **no** local account is refused
      ("Request to authenticate with Google has been denied…") and creates **no** user (check
      _Directory → Users_ in the Authentik admin UI). This is the invitation-only guarantee.
- [ ] **(#364, the one thing CI cannot reach at all.)** Signing in with a Google account whose
      verified address **does** match an existing, email-verified local account lands in the app on
      **that** account — no duplicate user is created, and _Directory → Users → that user → source
      connections_ now shows Google. This is the only check that proves Google really returns
      `verified_email: true` in its userinfo; every automated test synthesizes that payload. If it
      is instead **denied**, the flag is missing or non-boolean — check _Events_ in the admin UI and
      re-read `docs/architecture/auth.md` §8.14 before changing anything.
- [ ] Signing out and using **Continue with Google** again lands on the same account **immediately**
      — the second time it resolves on the stored subject, not the email.
- [ ] Signing in with a password, connecting Google under _Settings → Connected services_, then
      signing out and using **Continue with Google** lands in the app on the **same account** —
      same apiaries, same organization.
- [ ] That federated session's token carries the **same `sub`** as the password session (decode
      `localStorage["bk.id_token"]`), and the app needed no reconfiguration — the D-7 boundary.
- [ ] **Sign out** from that federated session returns to the login screen and a fresh page load
      does not restore it (the server-side SSO session was revoked).

`scaleway-up.sh` ends fully **GitOps-bootstrapped** (it applies the
[`beekeepingit-gitops`](https://github.com/TiagoJVO/beekeepingit-gitops) repo's `clusters/<env>/`
— Flux sources + the cert-manager `ClusterIssuer`), so a fresh cluster converges on its own;
`SKIP_GITOPS_BOOTSTRAP=1` opts out. This is the opposite of `dev-up.sh`, which deliberately skips
bootstrap so the local checkout (not `main`) is what gets deployed.

## Layout

| Path                                                         | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`cluster/`](cluster/)                                       | Local k8s cluster (k3d) bring-up (`up.sh`) and teardown (`down.sh`); whole-environment single-command bring-up/teardown (`dev-up.sh`/`dev-down.sh`, `#22`); Scaleway Kapsule staging/prod bring-up/teardown (`scaleway-up.sh`/`scaleway-down.sh`, D-26) and data-preserving pause/resume (`scaleway-scale-down.sh`/`scaleway-scale-up.sh`, `#539`), with shared preamble/prereq logic (`scw-common.sh`, `scw-cluster-prereqs.sh`) and env/secrets loading (`env.sh` + `.env.example`) |
| [`helm/beekeepingit/`](helm/beekeepingit/)                   | The Helm **umbrella chart** — see its own [README](helm/beekeepingit/README.md) for the subchart/values conventions                                                                                                                                                                                                                                                                                                                                                                   |
| [`helm/observability/`](helm/observability/)                 | The **observability stack** chart (#87) — its own Flux `HelmRelease`, deployed after MinIO; see its [README](helm/observability/README.md)                                                                                                                                                                                                                                                                                                                                            |
| [`gitops/`](gitops/)                                         | **Flux** GitOps wiring that reconciles the charts onto the cluster from this repo — see its own [README](gitops/README.md)                                                                                                                                                                                                                                                                                                                                                            |
| [`ci/`](ci/)                                                 | Probes CI execs **inside** cluster pods, where the assertion can't be made from outside — today `authentik-federation-probe.py` (#363), run through `ak shell` in the Authentik worker by `helm-e2e.yml`                                                                                                                                                                                                                                                                              |
| [`observability-smoke-test.sh`](observability-smoke-test.sh) | Fires a correlated trace+log+metric through the OTel Collector — a verification aid until `#23`'s services emit real telemetry                                                                                                                                                                                                                                                                                                                                                        |
| [`grafana-open.sh`](grafana-open.sh)                         | Dev convenience: fetches Grafana's admin password, port-forwards it, and opens the browser                                                                                                                                                                                                                                                                                                                                                                                            |

Postgres+PostGIS, the OIDC provider (Authentik — [ADR-0016](../docs/adr/0016-replace-keycloak-with-authentik.md),
originally Keycloak at **#84**), MinIO and the gateway are the umbrella chart's first real
subcharts. **PowerSync** (self-hosted Open Edition, [ADR-0005](../docs/adr/0005-sync-engine-choice.md))
lands with **#22** — see [`docs/architecture/walking-skeleton.md`](../docs/architecture/walking-skeleton.md)
§7.1. The walking-skeleton services + PWA subcharts, plus PowerSync's real org-scoped
Sync Rules and the `sync`-service JWKS connector, land with **#23**/**#106**, wiring into this
umbrella chart rather than standing up their own release.

The **observability stack** (OTel Collector, Prometheus, Grafana, Loki, Tempo — `NFR-OBS-1`)
landed with **#87**: see
[`docs/architecture/platform.md#observability`](../docs/architecture/platform.md#observability)
for the design.
