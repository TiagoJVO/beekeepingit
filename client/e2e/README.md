# client/e2e — walking-skeleton end-to-end test

Playwright test of the M0 slice ([#23](https://github.com/TiagoJVO/beekeepingit/issues/23) §7.3):
**log in → create an apiary (with free-text notes, FR-AP-8) → go offline → edit →
reconnect → assert it synced server-side → reload → assert the local state
converged → a fresh client converges via download sync (hive count and notes) →
log out.** It drives the deployed Flutter Web PWA
through the gateway and asserts against the `apiaries` service, so it needs the
**full slice deployed** (see [`infra/README.md`](../../infra/README.md) for the
k3d bring-up).

Runs in CI (`.github/workflows/helm-e2e.yml`, NFR-TST-1, `#162`) against a fresh
k3d cluster the workflow itself brings up — no separate deployed environment
needed. Gated on changes under `infra/**` or `client/**` (dorny/paths-filter),
same as the rest of that job — any client change re-runs the slice, not just
edits to this e2e, precisely because the image under test comes from the same
commit (below). The **PWA image is built in-job from the checked-out
commit** and imported into the cluster (#236) — not pulled as the last-published
`client:latest`, which only updates on merge to main and would make the e2e test
main's client bundle instead of the commit under test. The apiary the create step
leaves behind is deleted in `afterAll` (`tests/slice.spec.ts`) via the same REST
API the app uses.

A third spec, **`tests/stock-declarations.spec.ts`** (#296/#298, FR-AP-9/FR-AP-10),
covers the beekeeper **registration number** and the **stock-declaration log** —
now two separate screens: set the organization's registration number on the
organization-details screen → record a stock declaration on the declarations screen
→ assert a **fresh client downloads both** → delete the declaration again. The
fresh-client step is the reason it exists. `stock_declarations` is a new table with
a new Sync Rules entry, and `registration_number` is a new column on an
**explicit** sync-rules column list — the exact shape that fails **silently** (the
row never arrives, the column just stays NULL, and every local-only test still
passes because the device that wrote it has it locally). That is the same failure
`notes` hit when #33 rewrote the apiaries entry from `SELECT *`. Declarations have
no REST surface (sync only, like `apiary_counters`), so the UI delete at the end is
the teardown — and doubles as coverage of the one lifecycle operation a counter
deliberately lacks.

The server-side apply semantics (LWW, conflict log, idempotency, tombstones) and
the sync coordinator are additionally covered by fast **Go integration tests**
(`services/apiaries`, `services/sync`) that run in CI without a browser.

A second spec, **`tests/verification.spec.ts`** (#361, NFR-SEC-1), covers the
login-time email-verification flow end to end: unverified login held at the
IdP's email stage → one-time link read from the **Mailpit** sink's API → real
`email_verified: true` claim → the **invitation accept-on-login** path
(FR-ONB-3/#170: an admin-created invitation stays `pending` while the login is
held and is auto-claimed once verified) → and an email-change attempt through
Authentik's real user-settings flow executor being **rejected**
(`default_user_change_email` is off — the upstream default at the pinned
version and not blueprint-pinnable, so this assertion is the live pin on the
control that closes the #170 shape). It needs a **fresh blueprint-seeded
stack** plus `E2E_MAILPIT_URL` (helm-e2e.yml port-forwards the sink and sets
it) and self-skips when the env is absent; its tests are order-dependent
within the file.

**`tests/cache-headers.spec.ts`** (#621, FR-PL-1) is the cheap one — no login,
and it deliberately does **not** wait for the Flutter app to boot (it only needs
a same-origin document to fetch from, so it retries `/` just while a cold gateway
still answers its own 5xx page, rather than using `gotoAppRoot`'s 120s glass-pane
wait — otherwise an unrelated app-boot regression would report as a cache-headers
failure). It is the only place the response headers served **through the gateway,
from the real nginx container** (`client/nginx.conf`) are asserted. It reads `/`,
`/index.html`, an SPA-fallback route, `main.dart.js`, the Flutter loader scripts,
`canvaskit/canvaskit.js`, `version.json`, `manifest.json` and a bundled asset
through in-page same-origin `fetch(…, { cache: "no-store" })` (Playwright's
Node-side `request` fixture can't resolve the dev hostnames, and the browser's own
cache must not be allowed to answer). Each must be `200` with
`Cache-Control: no-cache` — nothing `immutable`, because `flutter build web` emits
no content-hashed filenames — **and** must carry the `Content-Type` of its asset
class: nginx's `try_files` fallback answers any missing path with `200` +
`index.html`, so without that second check a renamed Flutter output (a `--wasm`
build's `main.dart.mjs`, a relocated CanvasKit) would leave the spec green while it
just re-measured the document's headers ten times. It doubles as the guard for
nginx's `add_header` **inheritance trap** (#89): an `add_header` inside a
`location {}` cancels every server-level one, so the spec also asserts
`X-Content-Type-Options: nosniff`, `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` still arrive — COOP/COEP named
explicitly because they break first: losing cross-origin isolation takes
`SharedArrayBuffer`, and with it PowerSync's wasm/OPFS sync worker.

The fresh-client **notes** assertion doubles as the regression guard for the
PowerSync sync-rules column list
(`infra/helm/beekeepingit/charts/powersync/values.yaml`): the
`apiaries.apiaries` SELECT there is an explicit list, and a column missing from
it (as `notes` once was, FR-AP-8/#196) silently stays `NULL` on fresh devices —
no other layer surfaces that.

## Skipped guards (`test.fixme`) — real bugs found by wiring this e2e

An assertion the e2e correctly caught is marked `test.fixme` (skipped, not
loosened) with the diagnosis inline, so the job stays green while the bug is
tracked. Unskip it when its bug is fixed:

- **RP-initiated logout doesn't return to the app** (#237). After Sign out,
  Authentik shows its own "You've logged out" confirmation interstitial instead
  of redirecting to the app's `post_logout_redirect_uri`, so the browser never
  gets back to `/login`. Fix is on the Authentik/logout-flow side.

## Watched flake — PowerSync's download stream never establishes (#246)

Seen **once**, on `helm-e2e` run
[29251456225](https://github.com/TiagoJVO/beekeepingit/actions/runs/29251456225)
attempt 2 (2026-07-13), and not reproduced since. It is **not fixed** — it is
watched, because the one occurrence predates the diagnostics that would settle
it. Read this before re-diagnosing from scratch.

**Signature.** The fresh-client download-convergence assertion in
`tests/slice.spec.ts` times out while everything else passes. In the Playwright
trace: `GET /v1/sync/token` returns **200 every ~5.0s, continuously** (the
PowerSync SDK's engine retry — fetch credentials, attempt the stream, fail,
wait 5s), the sync pill stays **"Offline"**, uploads and local reads keep
working. The connectivity probe (#55/#222) fires **once** and passes, so it is
not the gate: its own backoff would be exponential, not a flat 5s. Deterministic
within a run (both in-test attempts failed); a plain re-run was green on an
equivalent image.

**Already eliminated** — each checked at the time, do not re-spend a run on
them: the SyncGate/probe; the enforced CSP (Report-Only); COEP on the worker
scripts; the self-signed cert inside the SharedWorker; JWKS staleness in its
simple form (powersync-service refreshes on an unknown `kid`); worker-asset and
SDK version drift (both version-pinned by `pubspec.lock` + `setup_web`); and the
`offline_access` scope change that was the original suspect (exonerated by the
green re-run).

**Why the first occurrence was undiagnosable.** The stream itself runs inside
`powersync_sync.worker.js`, a SharedWorker whose network Playwright does not
trace — the page-side evidence tops out at the 5s retry loop. The server side
should have covered that, but `helm-e2e.yml`'s on-failure
`kubectl logs -l app.kubernetes.io/part-of=beekeepingit` selects **pods** while
that label was only on the **Deployments**, so it matched nothing and dumped
nothing. Fixed in #246 (the shared label helper is now on the pod templates);
#242 had already added explicit `powersync`/`sync`/`traefik` dumps.

**Evidence a recurrence now leaves**, all in the job's "Diagnostics (on
failure)" step: every owned pod's logs via the (now live) `part-of` selector;
`--timestamps` on the `powersync`, `sync` and `traefik` dumps so they can be put
on one timeline; each Deployment's `--previous` logs; and — from #246 — a
`sync-token signing key ready` line with the signing **`kid`** logged by every
`sync` boot.

**Watch procedure**, on the next occurrence:

1. Confirm the signature above from the `playwright-report` artifact (flat ~5s
   `/v1/sync/token` 200s, probe passed once). A different cadence is a different
   bug.
2. In the diagnostics step, read `deploy/beekeepingit-powersync` first — it is
   the only place a rejected sync-stream connection is named. Classify the
   rejection: **auth** (a `kid`/JWKS/audience complaint), **replication** (the
   engine has no checkpoint to serve yet), or **no connection reaching it at
   all** (then it is the gateway — check the `traefik` dump).
3. If it is auth, compare the `kid` PowerSync rejects with the `kid` in
   `deploy/sync`'s `sync-token signing key ready` lines, and compare their
   timestamps with the blanket `kubectl rollout restart` (#215) earlier in the
   job. In dev/CI `sync` signs with an **ephemeral per-boot key**
   (`services/sync/token/token.go`, `LoadOrGenerateKey`), so that restart
   rotates the `kid` under a PowerSync that is restarting at the same moment.
   A mismatch confirms the restart-ordering hypothesis — the fix is then to
   order the restart (settle `sync` before `powersync`) or to give dev/CI a
   stable signing key, and it stops being a guess.
4. If it is replication, the same two dumps plus the CNPG logs show whether the
   logical-replication slot survived the restart.
5. Either way, attach the dumps to a **new issue** (or reopen #246) with the run
   id — that is the evidence trail this section exists to make collectable.

The restart ordering was deliberately **left unchanged** by #246: changing it
speculatively would have removed the one signal that can still confirm or kill
the hypothesis, on a flake that has not recurred in the ~7 weeks of `helm-e2e`
runs since.

## Cold-stack robustness

The e2e runs against a k3d stack the CI job brings up fresh each run, so the spec
hardens its first interactions against a not-yet-warm gateway rather than assuming
instant readiness:

- **`gotoAppRoot`** reloads until the Flutter app actually boots — a freshly-ready
  gateway can answer `502 Bad Gateway` for a short window, and a plain `goto()` then
  lands on a static error page that never becomes the app. The workflow also warms
  the gateway (polls the PWA + OIDC discovery) before starting the browser.
- The login helper waits for the app's Sign in button to be visible before clicking,
  and gives the OIDC callback a generous navigation budget.
- The reconnect-sync step taps the app's **Sync now** override after reconnect: the
  connection-quality gate (#55) doesn't re-probe promptly on connectivity-return
  (it waits out its exponential backoff — up to ~2 min — with no online-event
  interrupt), so a queued write can sit unflushed. That's a real FR-OF-3
  responsiveness gap (see the code comment by the nudge and the PR notes), not just
  CI slowness; the nudge is the intended user action and can be dropped once the
  gate re-probes on reconnect.

## Run

```sh
cd client/e2e
npm install
npm run install-browsers          # chromium
# Point at the deployed stack (defaults target the local k3d gateway; the OIDC
# provider lives on the separate auth.beekeepingit.local host — the test's
# host-resolver rule maps both to loopback):
E2E_BASE_URL=https://app.beekeepingit.local:8443 \
E2E_API_URL=https://app.beekeepingit.local:8443 \
npm test
```

> **Flutter Web note:** the PWA renders to canvas, so the test enables Flutter's
> accessibility semantics (via the a11y placeholder) to get a queryable DOM. If
> semantic selectors prove brittle against a given build, the design's documented
> fallback is a Flutter `integration_test` (§7.3).
