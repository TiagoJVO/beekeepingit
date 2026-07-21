# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## Deploy pipeline (D-26, D-27) — post-merge remaining work

Phases 0–4 shipped in #330 (image-automation removed; `infra/gitops/` split into
`beekeepingit-gitops`; release-triggered `release-deploy.yml` + PWA build path), recorded in
[D-27](requirements/decisions.md) / [ADR-0018](docs/adr/0018-release-triggered-deploy-pipeline.md).
`DEPLOYMENT_PIPELINE_PLAN.md` stays until Phase 6 is done, then delete. Remaining:

- **Re-point the live dev cluster's Flux** (post-#330, manual, in WSL2) — if the dev cluster was
  GitOps-bootstrapped, `infra/gitops/` leaving `main` makes its Kustomization go stale:
  `git clone https://github.com/TiagoJVO/beekeepingit-gitops && kubectl apply -f beekeepingit-gitops/clusters/dev/`.
  No-op if you only use `dev-up.sh`'s local direct-apply loop.
- **Phase 5 — real domain `melargil.pt`** (naming confirmed, consistent `-rc`): prod
  `beekeepingit.melargil.pt` + `auth.beekeepingit.melargil.pt`; staging
  `beekeepingit-rc.melargil.pt` + `auth.beekeepingit-rc.melargil.pt`. In order, after the cluster
  is up so hosts resolve: (1) Scaleway reserved IP per env → Traefik's LoadBalancer; (2) Cloudflare
  A records (DNS-only) → those IPs; (3) swap the nip.io / `.example` values for the real ones in the
  gitops repo's `apps/{staging,prod}/beekeepingit-helmrelease.yaml`, `environments/{staging,prod}.yaml`,
  and `release-deploy.yml`'s `publish-client` dart-defines. cert-manager stays HTTP-01 unless the
  Cloudflare proxy is enabled.
- **Phase 6 — end-to-end verification** — bring staging up, cut `v0.0.1-rc1`, walk the whole chain
  (build → tag-bump PR → merge → Flux → real domain + trusted cert → login). First live exercise of
  the new pipeline.
- **Switch staging's PWA image tag off `staging-manual`** — the gitops repo's
  `apps/staging/beekeepingit-helmrelease.yaml` still pins `pwa.image.tag: staging-manual`; it
  switches automatically when the first `-rc` release's tag-bump PR sets the version and is merged
  (Phase 6). Don't hand-edit it to a non-existent tag before then.
- **Harden `main`'s required status checks** (deferred from the Phase-6 discussion; not a deploy
  blocker). `main` currently requires only `ci`, `k3d cluster + helm test`, `helm lint & template
dry-run`, and the PR-title check (strict). These run but are **not** required, so a red one
  wouldn't block a merge:
  - `security-scan` — `trivy (dependencies + secrets)` + `govulncheck (Go modules)`: stable
    contexts that run on every PR, so safe to add to the required set directly (leave out
    `trivy (IaC / misconfig)`, which is report-only by design).
  - `build-publish`'s image build+scan — matrixed (`build <component>`), a dynamic/skippable
    context; add a small aggregator job (`needs: [build]`, one stable context) before requiring it.
  - `contracts-ci` — path-filtered on its trigger (`contracts/openapi/**`), so it can't be required
    as-is (a skipped-because-not-triggered required check leaves PRs pending); would need the
    always-run + check-relevance-inside pattern helm-e2e uses first.
  - Low stakes under D-27: merge-to-`main` images are artifacts (dev-only `latest`, overwritten),
    and the deployable path (`release-deploy.yml`) already gates each publish behind lint/test/scan,
    prod behind the `production` approval, and behind the human merging the tag-bump PR.
- **Observability is intentionally not deployed anywhere** (dev, staging, or a future prod) — a
  deliberate choice, not a gap to revisit.
- Minor, not blocking: the per-environment PWA URLs in `release-deploy.yml`'s `publish-client` job
  and each `infra/helm/beekeepingit/environments/*.yaml` overlay are two independently-maintained
  copies of the same values — no shared source yet. Worth a GitHub issue if it drifts.

## Pin the primary action on the remaining full-screen forms (FR-UX-1, D-18)

- **What**: `apiary_form_screen.dart` now keeps Save (and edit-mode Delete) in a pinned
  action bar outside its scroll view, matching what
  `journey_quick_create_sheet.dart` / `todo_quick_create_sheet.dart` already do. The other
  full-screen forms still put their primary action as the last child of a
  `SingleChildScrollView`: `activities/add_activity_screen.dart`,
  `journeys/journey_form_screen.dart`, `todos/todo_form_screen.dart`.
- **Why it wasn't done here**: none of them embeds a gesture-swallowing surface like the
  apiary form's 220px `FlutterMap`, so their Save is merely below the fold, not
  _unreachable_ — the user can still scroll to it. They do contain bounded, inner-scrollable
  pickers (`apiary_multi_select_field.dart`, `todo_apiary_picker_field.dart`,
  `todo_assignee_picker_field.dart`) that trap a drag started over them, so the hazard is
  the same in kind, just milder. Converting three screens' layouts (and re-checking each
  one's widget tests, several of which rely on tall viewports / `ensureVisible`) is more
  than the small, safe consistency fix this branch could absorb.
- **Where**: the three files above; pattern to copy is `apiary_form_screen.dart`'s `build`.
- **Status**: pending — promote to a GitHub Issue if not picked up with the next UX pass.

## Not covered by an automated test: `todo_form_screen.dart`'s date picker

- **What**: actually driving the real `showDatePicker` calendar UI to pick a
  _new_ due date — only the pre-fill/display and the clear-button path are
  tested.
- **Why**: no existing precedent in this codebase for testing that
  interaction (`add_activity_screen.dart`'s own `occurredAt` date field is
  the same shape and isn't UI-driven in its own tests either).
- **Status**: not blocking; a reviewer wanting this covered should add it as
  a follow-up.
