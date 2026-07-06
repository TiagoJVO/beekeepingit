# Follow-ups ledger

> Session-persisted pending work, committed for continuity and progression tracking.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist + cross-session
> handoff for in-flight branches. Promote durable items to Issues; tick/prune as they land.
>
> This file should trend toward **empty**. An entry belongs to the PR that added it and gets
> resolved — pruned or promoted to an Issue — by the time that PR merges, not carried forward
> as permanent history (git history already keeps that). If you're reading this and a section
> below references an issue/PR that's since closed, that's a bug: prune or promote it.

## #22 (PR #152, before merge) — verified live against the local `beekeeping` k3d cluster (2026-07-06)

A clean, uninterrupted `infra/cluster/dev-down.sh` → `infra/cluster/dev-up.sh` pass from a
torn-down cluster completes successfully end-to-end (`real 3m4s`), closing out the one item this
PR's description flagged as not yet done. Getting there surfaced three real bugs in `dev-up.sh`'s
own orchestration (not the chart's steady-state behavior), all fixed and reverified on that clean
run:

- **Deadlock: `helm upgrade --install --wait` vs. the schema-grants post-install hook.** The
  `powersync` role can't pass its `powersync_storage` permission check until
  `charts/postgres/templates/schema-grants-job.yaml`'s Job — a `post-install` hook, since that
  role doesn't exist yet at install time — grants it. But Helm only runs post-install hooks
  _after_ `--wait` is satisfied for the main release resources, so PowerSync waiting to be ready
  and the hook that would make it ready were waiting on each other; `--wait` would eventually time
  out and fail the whole release. Fixed by dropping `--wait` from the umbrella
  `helm upgrade --install` in `dev-up.sh`/`infra/README.md` and waiting on each component
  explicitly afterward instead (already done for PowerSync/Keycloak/MinIO; added for Postgres).
  Symptom while broken: `beekeepingit-powersync` `CrashLoopBackOff`, logs showing
  `Fatal startup error - exiting with code 150. permission denied for database powersync_storage`.
- **`kubectl wait` doesn't wait for a pod to _exist_.** It errors immediately with "no matching
  resources found" if its selector currently matches zero pods, rather than polling for one to
  appear — a real race against the Deployment/StatefulSet/Flux HelmRelease that creates the pod a
  moment after the resource owning it is applied. Fixed with a small `wait_for_pod` helper in
  `dev-up.sh` that polls for a match first, bounded by the same timeout so a wrong/stale selector
  still fails loudly instead of hanging forever.
- **Wrong MinIO readiness selector.** `dev-up.sh` waited on `app.kubernetes.io/instance=minio`,
  but the vendored `charts.min.io` chart predates that label convention and only sets legacy
  `app=minio,release=minio` labels — confirmed via `kubectl get pod --show-labels` against the
  live pod. Fixed the selector to match.

All of `#22`'s acceptance checks reconfirmed on that clean run: `wal_level=logical` +
`powersync_storage` DB + `powersync` role (`replication=t`, confirmed able to `CONNECT` to
`powersync_storage`) + `powersync` publication (`puballtables=t`, in the `beekeepingit` database)
all present; PowerSync reaches a clean steady state (one expected restart from the race above,
then stable liveness 200s); `helm test` (PostGIS smoke query) succeeds; Keycloak realm reachable
through the gateway (200); MinIO health endpoint returns 200; `dev-down.sh` tears down with zero
orphaned k3d volumes/containers afterward.

Earlier findings from the same verification effort (still relevant, not yet superseded):

- **PowerSync needs `POWERSYNC_CONFIG_PATH`.** The image doesn't infer its config location from
  the mounted volume — it looks for `/app/powersync.yaml` by default and exits fatally if that
  literal path is missing. Fixed by setting `POWERSYNC_CONFIG_PATH=/config/service.yaml` (confirmed
  against `powersync-ja/self-host-demo`'s reference `docker-compose` service).
- **The placeholder sync-config query needs a real table.** `SELECT 1 AS id WHERE false` fails
  PowerSync's sync-rules validator ("Must have a result column selecting from a table") — a
  literal projection with no `FROM` doesn't qualify, and neither does selecting a literal column
  from a table. Fixed by selecting an actual column (`schemaname`) from Postgres's always-present
  `pg_catalog.pg_tables`, still gated by `WHERE false` so it never returns/replicates a row.
- **`helm dependency build` must re-run after every local subchart edit.** `infra/helm/beekeepingit/charts/*.tgz`
  is a packaged snapshot Helm actually installs from (not the live `charts/<name>/` source
  directory) — editing a subchart's templates/values without rebuilding silently installs the
  stale snapshot.
- **The documented "apply Keycloak/MinIO HelmReleases directly for local-only testing" step
  never actually worked standalone.** Both files' `dependsOn: [beekeepingit]` targets the
  _HelmRelease object_ named `beekeepingit`, which only exists once the cluster is
  GitOps-bootstrapped (`infra/gitops/clusters/dev/`) — bootstrapping that, though, makes Flux
  deploy the umbrella chart from `main`, defeating local branch testing. `dev-up.sh`/`dev-down.sh`
  fix this by stripping `dependsOn` at apply-time for this direct-install path only (committed
  files untouched).

**Status:** done. Prune this whole entry when `#152` merges — nothing else is outstanding on this
branch.
