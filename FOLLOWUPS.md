# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## Security baseline (`fix/EPIC-14-89-security-baseline`, #89) — follow-ups

#89 closed the CSP/headers, trivy-config, and NetworkPolicy gaps; three items are deliberately
deferred rather than built here (each already has an inline comment at its source pointing back
here):

- **CSP: report-only → enforcing.** `client/nginx.conf` ships
  `Content-Security-Policy-Report-Only`, not the enforcing header — this repo's CI can't run a
  real browser against the built Flutter web app (no live cluster in CI), so a subtly-wrong
  directive for the actual CanvasKit/skwasm/PowerSync wasm loading path would silently break the
  app rather than just report. **Action:** once validated against a real browser (dev/staging),
  flip to the enforcing `Content-Security-Policy` header.
- **`client/nginx.conf`'s CSP `connect-src` hardcodes `auth.beekeepingit.local:8443`** — today
  the only real auth-host value in the repo (`environments/{staging,prod}.yaml` don't define a
  different one yet). **Action:** when a real non-local auth host ships, template this file
  per-environment (e.g. envsubst at container start) instead of a hardcoded string.
- **PowerSync's Deployment security context is partial** (`charts/powersync/templates/
  deployment.yaml`): `allowPrivilegeEscalation: false` + drop `ALL` capabilities are set, but
  `runAsNonRoot`/`readOnlyRootFilesystem` are NOT, because `journeyapps/powersync-service` is a
  third-party image with no in-repo Dockerfile and its runtime user / on-disk writes aren't
  verified against a live cluster here. The two checks (KSV-0014/KSV-0118) are ignored
  repo-wide in `.trivyignore` as a result (see that file's own comment on the scoping caveat).
  **Action:** validate against a live rollout, apply the two settings, and delete the
  `.trivyignore` entry (restoring full KSV-0014/KSV-0118 coverage for any future Deployment).
- **NetworkPolicy label assumptions not independently verified against a live cluster**
  (no live cluster available while writing #89): Authentik's bundled Postgres subchart pod
  label (`app.kubernetes.io/name: postgresql`, `app.kubernetes.io/instance: authentik`) and
  CoreDNS's `k8s-app: kube-dns` label on k3d. If either differs, `helm-e2e.yml`'s Authentik
  readiness hook / general pod connectivity will surface it as a failure to triage — the CI k3d
  job is the live test this issue's own instructions call for.
- **NetworkPolicy is not enforced by k3d's default CNI (Flannel)** — the policies are shipped
  anyway because they're the correct, declarative statement of intent and take effect
  automatically on any NetworkPolicy-enforcing CNI. Not an action item, just documented so a
  future reader doesn't assume traffic is actually restricted on the local/CI cluster today.
- **NetworkPolicy default-deny doesn't yet cover the observability stack's internal traffic**
  (`infra/helm/observability` — its own Flux HelmRelease, but the SAME `beekeepingit-dev`
  namespace, ADR-0013): `charts/networkpolicy`'s default-deny is namespace-wide, but
  `.Values.edges` only enumerates this umbrella's own services + Authentik + Postgres, not
  otel-collector → Loki/Tempo/Prometheus or Grafana → Loki/Tempo/Prometheus. Those are four
  vendored third-party charts whose pod labels weren't verified against a live cluster while
  writing #89 (guessing them risked being wrong for a stack outside #89's explicit scope, worse
  than leaving the gap documented). **Action:** once verified against a live cluster, add the
  observability edges to `charts/networkpolicy/values.yaml`'s `.Values.edges` the same way the
  beekeepingit-umbrella ones are — same mechanism, just needs the real labels confirmed first.
  Until then, this default-deny would break observability's internal traffic on any CNI that
  actually enforces NetworkPolicy (not k3d's default Flannel — see the point above).

**Still blocked on the user (not part of this PR, tracked in
`infra/gitops/image-automation/README.md`):** Flux image-automation's `ImageUpdateAutomation`
needs a Git **write credential** (deploy key or PAT) provisioned as a cluster secret before that
directory can move into a reconciled path — a secrets-management step only the user can do.

## Offline UX: sync status/queued changes/retry (`feat/EPIC-06-offline-sync-ux`, #58) — before-merge note

#58 builds the sync-status UI (real connectivity + pending count via `PowerSyncDatabase
.statusStream`/`getUploadQueueStats`, a non-blocking "superseded" toast, manual "sync now",
`client/lib/shell/sync_status.dart` + `client/lib/core/sync/`) against what already exists.

**Gap found, not built here (by design — flagging per the issue's own instructions):** the
**connection-quality gate** (FR-OF-3, [sync.md](docs/architecture/sync.md) §7.1 — "connect/flush
only when a quality probe passes, ~usable 3G, with backoff") does not exist yet anywhere in the
client (no gateway-reachable health/probe endpoint, no Network Information API / `connectivity_plus`
usage). sync.md §10 itself hands this mechanism to **"EPIC-06 (#55/#58)"**, and re-reading **#55**
("Client local store + sync integration") confirms **#55, not #58, owns building the actual gate**
(its AC explicitly includes "connect/flush only when a quality probe passes... exponential backoff
and a manual sync now override — mechanism in sync.md §7.1") — #55 is still open, so the gate is
simply not built yet anywhere. #58 does not attempt to build a parallel gate; it only adds the
manual "sync now" override (already in scope per #58's own AC) and will surface the gate's
"waiting for better signal" state once #55 lands (no rework expected — `SyncStatus` has room to
grow additively). **Action:** none needed here beyond this note; #55 already tracks the real work.

## Keycloak → Authentik migration — post-merge follow-ups

The migration (contract + ADR-0016 + D-7; WS-A infra, WS-B backend, WS-C client, WS-D docs) shipped in
**#191** (merged). Remaining coordinator follow-up (to promote to a GitHub Issue, then prune here):

- **Backlog grooming** — rename **#72** (Keycloak → OIDC auth), retarget **#98** / EPIC-14 **#15**
  auth-hardening scope to Authentik (flows/blueprints/secrets), reconcile other open Keycloak-mentioning
  issues.

(Live browser-login re-validation is already tracked as **#193**, opened separately — no longer
duplicated here.)

## Milestone/stream regroom (D-14) — follow-ups

Flat **M0–M5** re-sliced into a per-feature ladder + cross-cutting streams; the GitHub
Issues/Milestones/dependency edits are already applied (this PR records the model in **D-14**).
Pending (promote to Issues, then prune here):

- **Scope gates** — settle before sizing a feature's stories: `Q-MAP` → M2 (narrowed to
  offline-tile caching/provider; `Q-DIST`/`Q-SEARCH` already resolved via `D-*`, removed),
  `Q-JOUR` → M4, `Q-TODO` → M5, `Q-IMP` → M6, `Q-AICLOUD` → M8, `Q-NOTIF` → M9. Resolve via
  the `requirements-folder` skill (answer → `D-*`/`FR-*`, then delete the `Q-*`).
- **`#60`** ("history view per apiary/activity/journey", now M3) may want splitting per entity during grooming.
- **Provisional stream-story placements** — `#56–59`/`#61–62`/`#165` → M2, `#90`/`#92` → M6 by
  "first need"; revisit if a thinner M2 is wanted.
- **Project board** — re-check any saved views that filtered the now-deleted `M2–M5`.

Rollback snapshot if needed: `scratchpad/backlog-backup-2026-07-11/` (+ `RESTORE.md`).

## Melargil prototype import — follow-ups

The product's interactive prototype ("Melargil") is now in-repo at `docs/design/melargil-prototype/` +
[`docs/design/prototype.md`](docs/design/prototype.md) as the **UI/UX guideline** (not a spec). It validates the
M0–M11 backlog and answers 6 open `Q-*`. This PR adds: the prototype in-repo, epic `**Prototype:**` links
(#2/#3/#4/#5/#6/#9/#13), 2 net-new stories, and spec-note refinements (#38/#49/#58/#65/#82). Pending:

- `FR-AP-8` (apiary notes, #196) and `FR-UX-2` (app-shell IA, folded into the field-first
  `FR-UX` track, #197) landed in `requirements/functional-requirements.md` (#199, merged) and are
  now **implemented** (#32/#196, #197) — no longer pending.
- **Feed the scope pass** — the prototype answers `Q-MAP`/`Q-JOUR`/`Q-TODO`/`Q-NOTIF` (see
  `docs/design/prototype.md`); use those when settling each remaining `Q-*` (answer →
  `D-*`/`FR-*`, delete the `Q-*`). `Q-DIST`/`Q-SEARCH` are already resolved and removed.
