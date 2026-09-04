---
name: deploy-and-operate
description: >-
  How BeekeepingIT's live environments are laid out and operated, and how to drive a release to
  one end to end: which environments exist, where each one's settings live as code (the
  beekeepingit-gitops repo, not this repo's environments/*.yaml mirror), the GitHub
  environments/secrets behind them, and the release → promotion-PR → Flux path. Use when asked to
  release, deploy, promote, roll back, or validate something live; when someone asks "is this on
  staging yet?" or "why isn't my change live?"; when bringing a cluster up/down or pausing it; or
  when adding an external credential. Asked for a release, the agent cuts it, watches the build,
  merges the promotion PR and confirms on the cluster that pods run the new version — reading the
  cluster is in scope, mutating it is not; a restart, a credential value, or anything destructive
  is flagged to the user with the exact command instead.
---

# Deploying & operating BeekeepingIT

Design owners: D-26 (Scaleway hosting), D-27 /
[ADR-0018](../../../docs/adr/0018-release-triggered-deploy-pipeline.md) (release-triggered,
PR-based promotion; chart pinned per its 2026-08-31 addendum),
[ADR-0022](../../../docs/adr/0022-durable-storage-pause-resume-not-volume-reattach.md)
(pause/resume). Mechanics: [`infra/README.md`](../../../infra/README.md) and
[`docs/architecture/platform.md`](../../../docs/architecture/platform.md). This skill is the map,
the runbooks and the traps — not a restatement of those.

**A trap here describes something that already bit, and every one names the state it is in.** A
trap marked settled is history: it explains why a guard or an ordering exists, so nobody undoes
it — it is **not** a checklist to re-verify on a release. Re-proving settled infrastructure costs
a release the time it was meant to save. So: when you close an issue this file cites, fix its
entry in the same change, and if a trap is now guarded in code, say so and say what still needs
doing (usually: prod, which has none of staging's setup yet).

## Boundaries

The agent drives everything that goes through GitHub or a public URL, and **reads** the cluster to
confirm (`kubectl get`, `kubectl rollout status`, `flux get`, and a read-only
`kubectl exec … ak shell -c "…print(…)"` for authentik's blueprint state). It does not:

- **mutate** the cluster — no `rollout restart`, `apply`, `delete`, `flux reconcile`, `helm`,
  `scw`, no `exec` that writes; a step that needs one is **flagged to the user with the exact
  command**, not run;
- destroy a cluster (`cluster-ops` `down`, `scaleway-down.sh`);
- handle a credential value (`gh secret set` is the user's, at a prompt);
- cut a bare (non-`-rc`) tag — that targets prod, which D-26 keeps closed until `Q-DR` and #90.

`cluster-ops` `up` / `scale-down` / `scale-up` are idempotent and non-destructive; the agent may
dispatch them when asked.

**Permissions.** `gh release create`, `gh run watch`, `gh pr checks`, `gh pr merge`,
`kubectl get`, `kubectl rollout status` and `flux get` are allowed in `.claude/settings.json`; the
permission classifier blocks them mid-run otherwise. A rule matches one plain command, so run
each command on its own — no `x=$(…)` capture, no `&&`, no `for` loop, no pipe into `grep`. If a
step is denied anyway, hand the user that one command, wait, and continue from the next step —
**never retry it as a different command** (`gh api`, a script, an equivalent flag).

**Cluster access.** The staging kubeconfig context is installed by `scaleway-up.sh`
(`scw k8s kubeconfig install`); check `kubectl config get-contexts` and pass `--context <name>`
after the verb on every command (`kubectl get … --context <name>`, so the permission rule still
matches). On Windows the tools live in WSL2 (`wsl kubectl …`, per `infra/README.md`). No context
⇒ flag it; do not install one.

**Reporting.** One report at the end, four lines: tag + sha, promotion PR (merged, link), the
landed evidence, and any flagged follow-up. Mid-run, speak only when blocked. Never summarise the
release contents in chat — the release notes are that summary.

## Environments

| Env       | Runs on                      | Namespace              | Hosts                                                                                                                                            | Chart source `ref`                                  | Deploys when                                                                 | GitHub env (gate)                                                       |
| --------- | ---------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `dev`     | local k3d (`dev-up.sh`)      | `beekeepingit-dev`     | `app/auth/admin.beekeepingit.local:8443`                                                                                                         | `branch: main` — deliberate, post-merge integration | every merge to `main` (only if GitOps was bootstrapped; `dev-up.sh` doesn't) | none                                                                    |
| `staging` | Scaleway Kapsule (D-26)      | `beekeepingit-staging` | `beekeepingit-rc.melargil.pt` plus the `auth.` and `admin.` prefixes — all three on Cloudflare DNS in one 3-SAN LE cert (#556 closed 2026-09-03) | `tag: <release>` — moved by the promotion PR        | a `*-rc*` release's promotion PR merges                                      | `staging-gate` (ungated; secrets + `APP_HOST`/`AUTH_HOST`/`ADMIN_HOST`) |
| `prod`    | none — inert scaffold (D-26) | `beekeepingit-prod`    | `*.beekeepingit.example` placeholders                                                                                                            | `tag: v0.0.0` placeholder                           | never, until `Q-DR` and #90 land                                             | `production-gate` (required reviewer; no secrets set today)             |

Plain `staging` / `production` GitHub environments also exist, unprotected and empty: they are the
**deploy record** written by the gitops repo's `notify-deploy` workflow, not a place for secrets.

## Where things live

| What                                                      | Where                                                                                                                             |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Helm umbrella chart                                       | this repo, `infra/helm/beekeepingit/`                                                                                             |
| **Deployed values** (what actually runs)                  | `TiagoJVO/beekeepingit-gitops` → `apps/<env>/beekeepingit-helmrelease.yaml`                                                       |
| Chart pin + Flux sources + bootstrap                      | gitops → `clusters/<env>/flux-system.yaml` (two `GitRepository`s: `beekeepingit` = chart, `beekeepingit-gitops` = manifests)      |
| Let's Encrypt `ClusterIssuer`                             | gitops → `clusters/{staging,prod}/cert-manager-issuer.yaml`                                                                       |
| Authentik / MinIO / observability releases                | gitops → `apps/<env>/*-helmrelease.yaml` (standalone HelmReleases, ADR-0012/0013/0016)                                            |
| `environments/<env>.yaml` in this repo                    | a **hand-synced mirror** of the gitops `values:` block for local `helm install` testing — never the answer to "what is deployed?" |
| URLs baked into PWA / admin images                        | `release-deploy.yml` (`--dart-define`, `VITE_*`) — `scripts/check-deploy-url-drift.sh` fails CI if they drift from the mirror     |
| Release pipeline                                          | `.github/workflows/release-deploy.yml` (trigger: `release: published`; 8–16 min for an rc)                                        |
| Promotion PR                                              | gitops repo, branch `deploy/<tag>`, title `chore(deploy): staging -> <tag>`; one check (`kubeconform`), no required review        |
| Cluster lifecycle                                         | `.github/workflows/cluster-ops.yml` → `infra/cluster/scaleway-{up,down,scale-up,scale-down}.sh`; local: `dev-up.sh`/`dev-down.sh` |
| External credentials (Scaleway, Cloudflare, SMTP, Google) | GitHub **environment** secrets on `staging-gate` / `production-gate`; local copy in `infra/cluster/.env` (gitignored)             |
| In-cluster secrets (Postgres, authentik, MinIO, Grafana)  | self-generated by the chart (`lookup` + `randAlphaNum`) — never in GitHub or git                                                  |
| Cross-repo tokens                                         | `GITOPS_PR_TOKEN` (this repo; opens the promotion PR), `DEPLOY_NOTIFY_TOKEN` (gitops repo; writes the deploy record)              |
| Deploy record                                             | <https://github.com/TiagoJVO/beekeepingit/deployments> — `*-gate` = approved to publish, plain name = promotion PR merged         |

```sh
# what staging actually runs — images and chart pin
gh api repos/TiagoJVO/beekeepingit-gitops/contents/apps/staging/beekeepingit-helmrelease.yaml --jq .content | base64 -d | grep -nE '^\s*tag:'
gh api repos/TiagoJVO/beekeepingit-gitops/contents/clusters/staging/flux-system.yaml --jq .content | base64 -d | grep -nE '^\s*(tag|branch):'
```

## What ships how

| Change                                                              | Reaches an environment via                                         |
| ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Go service, Flutter client, admin app code                          | release → images                                                   |
| Chart templates/values, authentik blueprint, NetworkPolicy, Ingress | release → chart (the promotion PR moves the `ref` with the images) |
| Gitops `values:` (hostnames, `gatewayNamespace`, …)                 | a PR to the gitops repo — a release does **not** touch these       |
| Docs, CI scripts, tests                                             | never                                                              |

**A merge to `main` changes nothing on staging or prod.** Merging the promotion PR is the deploy.

## Runbook — release to staging (agent-driven, end to end)

1. **Pre-flight.**

   ```sh
   git fetch origin main --tags
   gh release list --limit 3                                   # next tag = last -rc + 1
   gh run list --branch main --limit 8 --json workflowName,conclusion,headSha \
     --jq '.[] | "\(.conclusion)\t\(.workflowName)\t\(.headSha[0:7])"'   # all green on the candidate sha
   git log --oneline v0.0.1-rcN..origin/main                   # the delta
   git diff --stat v0.0.1-rcN..origin/main -- infra/helm/      # chart ships too? blueprint touched?
   ```

   Read staging's current versions (commands above). Images and chart pin must agree; if they
   don't, something is half-promoted — stop and report. Record the current PWA bundle stamp for
   step 7: `curl -sI https://beekeepingit-rc.melargil.pt/main.dart.js | grep -i last-modified`.

2. **Draft the notes** to the scratchpad. Convention (see rc13): prose, led by what a staging
   user will notice, issue numbers inline. Short. A release needs **no manual post-deploy step** —
   a blueprint change re-applies on its own (step 8); only add one if this particular delta
   genuinely carries one, and do not pre-announce an authentik nudge.

3. **Cut the release.** Target the sha, not `main`, so a concurrent merge cannot move it:

   ```sh
   gh release create v0.0.1-rcN+1 --target <sha> --title v0.0.1-rcN+1 --prerelease --notes-file <path>
   ```

4. **Watch the build.** `*-rc*` routes to `staging-gate` (ungated). Every Go service, the PWA and
   admin are linted/tested/built, Trivy-scanned (HIGH/CRITICAL blocks the push), pushed to ghcr as
   `<tag>`, then the promotion PR opens.

   ```sh
   gh run list --workflow release-deploy.yml --event release --limit 1 --json databaseId,displayTitle
   gh run watch <run id> --exit-status
   ```

   A failure in the `mise` toolchain fetch is a known transient (`gh run rerun <run id> --failed`,
   once). Anything else — Trivy, a test, a build — stop and report the failing job.

5. **Review the promotion PR.** Exactly two files, and the only changed lines are `tag:` values
   set to `<tag>`:

   ```sh
   gh pr list -R TiagoJVO/beekeepingit-gitops --head deploy/<tag> --json number,files
   gh pr diff <n> -R TiagoJVO/beekeepingit-gitops
   gh pr checks <n> -R TiagoJVO/beekeepingit-gitops --watch     # kubeconform
   ```

6. **Merge it** — this is the deploy. Merge commit, as every promotion so far:

   ```sh
   gh pr merge <n> -R TiagoJVO/beekeepingit-gitops --merge --delete-branch
   ```

7. **Confirm it landed — on the cluster.** Flux polls (sources every 1m, the HelmRelease every
   5m; no webhooks), so allow up to ~10 minutes. Flux saying "reconciled" is not health
   (`disableWait: true`) — the pods are the evidence:

   ```sh
   flux get sources git -A                                                        # beekeepingit source revision = <tag>
   flux get helmreleases -A                                                       # beekeepingit: Ready, chart revision = <tag>
   kubectl get deploy -n beekeepingit-staging -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image'   # every service, pwa, admin image ends :<tag>; READY = WANT
   kubectl get pods -n beekeepingit-staging                                       # nothing 0/1, CrashLoopBackOff or Error — that next to a healthy old pod is how rc12 looked "deployed"
   kubectl rollout status deploy/pwa -n beekeepingit-staging --timeout=120s       # repeat for any deployment whose READY lagged above
   ```

   Then the public surface, as a user would hit it:

   ```sh
   gh api "repos/TiagoJVO/beekeepingit/deployments?environment=staging&per_page=1" --jq '.[0].ref'   # = <tag>: the merge was recorded
   curl -sI https://beekeepingit-rc.melargil.pt/main.dart.js                                       # Last-Modified changed from step 1 = the new PWA bundle is serving
   curl -s -o /dev/null -m 15 -w '%{http_code}\n' https://beekeepingit-rc.melargil.pt/             # 200
   curl -s -o /dev/null -m 15 -w '%{http_code}\n' https://beekeepingit-rc.melargil.pt/v1/apiaries  # 401 = auth required = service up
   curl -s -o /dev/null -m 15 -w '%{http_code}\n' https://auth.beekeepingit-rc.melargil.pt/application/o/beekeepingit/.well-known/openid-configuration   # 200
   ```

   Re-check every minute while images still show the old tag; a brief non-200 while pods roll is
   normal. An image still on the old tag after 10 minutes, a pod not Running, or a probe staying
   down ⇒ stop and report exactly which. Do not "fix" it on the cluster.

8. **If the delta touched the authentik blueprint**
   (`infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml`), confirm it
   re-applied — it does so on its own, no restart: authentik hashes the mounted file and
   re-applies when the hash moves (rc14's applied 5 minutes after the merge, worker pod untouched).

   ```sh
   kubectl exec -n beekeepingit-staging deploy/authentik-worker -- ak shell -c "from authentik.blueprints.models import BlueprintInstance; [print(i.path, '|', i.status, '|', i.last_applied) for i in BlueprintInstance.objects.filter(path__icontains='beekeepingit')]"
   ```

   `successful` with `last_applied` after the merge = done. Anything else after ~15 minutes ⇒ the
   authentik runbook below, flagged to the user.

## Runbook — rollback

Revert the promotion PR's merge in the gitops repo; chart and images roll back together:

```sh
git clone --depth 20 https://github.com/TiagoJVO/beekeepingit-gitops "$SCRATCH/gitops" && cd "$SCRATCH/gitops"
git revert -m 1 <merge sha> && git push origin HEAD:revert/<tag>
gh pr create --title "revert(deploy): staging <- <previous tag>" --body "Reverts #<n>." --head revert/<tag>
```

Then merge as in step 6 and confirm as in step 7. Manual `kubectl`/`helm` edits to anything Flux
owns are reverted on the next reconcile (`prune: true`), so they are not a rollback path.

## Runbook — "is X live on staging?"

`git tag --contains <sha>` against staging's `tag:` values. Merged to `main` but in no tag ⇒ not
live. In a tag whose promotion PR is still open ⇒ not live. A gitops-values change ⇒ check the
gitops repo's history, not a release.

## Runbook — authentik blueprint did not apply (user runs it)

The chart renders the blueprint into ConfigMap `beekeepingit-authentik-blueprint`, mounted into
the authentik worker (a separate HelmRelease that references it by name). authentik re-applies a
file when its **hash** changes — a content change from a release lands on its own within minutes.
Two cases need a hand: the file is unchanged but an `!Env` credential rotated (PR #568 appends a
credential fingerprint to the file so the hash moves; `scaleway-up.sh` rolls the pods so the new
env is seen), and a file that simply never got a row. Force and **verify**:

```sh
kubectl -n beekeepingit-staging rollout restart deploy/authentik-worker
kubectl -n beekeepingit-staging exec deploy/authentik-worker -- ak shell -c \
  "from authentik.blueprints.models import BlueprintInstance; [print(i.path, '|', i.status, '|', i.last_applied) for i in BlueprintInstance.objects.all()]"
```

Two silent failure shapes, both of which look like "the feature just isn't there":

- **One invalid entry invalidates the whole file** — nothing applies, the task ends `exc:null`, and
  the outward symptom is OIDC discovery 404ing forever (PR #414). Evidence is only on the
  `BlueprintInstance` row.
- **`!Env [VAR]` (one element) raises `IndexError` at parse**, so no `BlueprintInstance` row is
  created at all. Always `!Env [VAR, ""]`; `scripts/check-federation-source-posture.sh` pins it
  offline — a YAML parse does not catch it.

## Runbook — cluster up / down / pause

`cluster-ops` (`workflow_dispatch`; inputs `environment`, `action`, `confirm`) runs the same
scripts as a local run. Staging runs immediately; prod waits for `production-gate` on every action.

| Action / script             | Effect                                                     | Data     |
| --------------------------- | ---------------------------------------------------------- | -------- |
| `up` / `scaleway-up.sh`     | create or reconcile + GitOps bootstrap + DNS + credentials | n/a      |
| `scale-down`                | delete the node pool + LB Services; control plane stays    | **kept** |
| `scale-up`                  | recreate the pool; fails if the cluster does not exist     | **kept** |
| `down` / `scaleway-down.sh` | destroys cluster, volumes, load balancers; needs `confirm` | **LOST** |

Pause/resume is `scale-down`/`scale-up` (ADR-0022); `down` is not "stop for the day" — CNPG's
`bootstrap.initdb` re-initialises an empty PGDATA rather than adopting an old volume. Locally,
`dev-up.sh` does not bootstrap GitOps (that would deploy `main` over your checkout); wrap any
mutating command in `infra/cluster/with-lock.sh` — the lock is per cluster name, shared by all
worktrees.

## Credentials

Only external credentials come from GitHub, as **environment** secrets on `staging-gate` /
`production-gate` — `cluster-ops.yml`'s `run` job carries the gate. A secret on `staging` or
`production` is silently ignored (the script takes its "not set — skipping" path and stays
green). `up` is idempotent, so it is also the rotation path; a hand-made `kubectl create secret`
is dropped on the next rebuild.

```sh
gh api repos/TiagoJVO/beekeepingit/environments/staging-gate/secrets --jq '.secrets[].name'
gh api repos/TiagoJVO/beekeepingit/environments/staging-gate/variables --jq '.variables[] | "\(.name)=\(.value)"'
```

Adding one is **four coordinated edits** (`scaleway-up.sh` block, `cluster-ops.yml` `env:`,
`.env.example`, the table in `infra/README.md`) — three fail silently; the README documents the
shape. Helm's `lookup` returns empty on the render where a Secret did not yet exist, so after
creating one a **second** render is needed
(`flux reconcile helmrelease beekeepingit -n flux-system --force` — the user's to run).

## Traps (each has bitten once)

- `environments/<env>.yaml` is not what runs. #556: staging's gitops values never got
  `gateway.adminHost` / `global.adminOrigin`, the dev default leaked into the ACME order, and cert
  renewal failed while the mirror looked right. The chart now refuses to render such a value
  (`gateway.assertPublicHostnames`).

  **Settled for staging — do not re-verify it on a release.** All three hostnames have A records
  and ride one 3-SAN cert; the gitops values carry both admin keys; the guard is deployed and
  passing. A release does not touch any of this, so checking hostnames, curling the admin host, or
  reading the guard template is not part of a release. The live check that a promotion actually
  reconciled is `flux get helmreleases -A` (step 7), and it covers a failed render of any cause.

  What stays worth knowing, because **prod has none of it yet** and this is the order to bring a
  new host up in: set the `*_HOST` variable, then run `cluster-ops` (`up`/`scale-up`) and confirm
  `cloudflare: A … -> <ip>` in the job log — the variable alone creates nothing — then land the
  gitops PR adding **both** `gateway.adminHost` and `global.adminOrigin`, and only then promote a
  chart carrying the guard. The order is load-bearing: naming a host that has no A record swaps a
  `rejectedIdentifier` rejection for a failed HTTP-01 challenge, and **one** failed authorization
  invalidates the entire multi-SAN order — app and auth TLS go down with the new host.

- The `GitRepository` `ref` is the only chart pin: Flux ignores `chart.spec.version` for git
  sources. `reconcileStrategy` must stay `Revision` — `Chart.yaml` is frozen at `0.1.0`, so
  `ChartVersion` would never deploy a tag. Before 2026-08-31 every env read `branch: main` and the
  chart deployed on merge, ungated. `flux get sources git -A` is the live check; on the Git side the
  gitops repo's `chart-pin` CI job (`scripts/check-chart-pin.sh`, #611) fails any PR that un-pins
  staging/prod.
- The promotion PR's `sed` rewrites every `tag:` in two files; the cluster file must carry exactly
  one (the chart source) — the gitops source stays on `branch: main` or the repo can't update
  itself.
- A green deploy can ship a dead pod: `disableWait: true` (needed — Helm's wait deadlocks on the
  `schema-grants` hook) plus no `healthChecks` means Flux never observes readiness. rc12
  crash-looped next to a serving rc11 and looked deployed. That is why step 7 reads pods and image
  tags, not the deploy record.
- `notify-deploy` records a "deploy" on any change to the staging/prod HelmRelease file, without
  observing Flux.
- PWA/admin images bake their environment's URLs at build time; one image cannot serve two
  environments. Stale URLs = login fails with `redirect_uri` mismatch.
- Prod carries no `suspend: true`: bootstrapping a cluster against `clusters/prod/` deploys the
  placeholders as-is, with `networkpolicy.gatewayNamespace` at the `kube-system` default that
  blocks every gateway→backend edge on Kapsule (ADR-0017).
- `dev` declares 4 of the 7 services and silently takes chart defaults for
  `activities`/`journeys`/`todos`.
