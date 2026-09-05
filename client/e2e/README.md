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
failure). It and `tests/compression.spec.ts` are the only places the response
headers served **through the gateway, from the real nginx container**
(`client/nginx.conf`) are asserted; they share that navigation helper, and the
content-type expectations, out of `tests/helpers.ts`. It reads `/`,
`/index.html`, an SPA-fallback route, `main.dart.js`, the Flutter loader scripts,
`canvaskit/canvaskit.js`, `service_worker.js`, `version.json`, `manifest.json` and a bundled asset
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

**`tests/compression.spec.ts`** (#670/#688, NFR-PER-1/FR-OF-1/C-2) is the second
login-free header spec, and it exists because the bundle used to be served with
**no compression at any layer** — `main.dart.js` (4.4 MB) and the CanvasKit
`.wasm` (5.8 MB) went over the wire whole. It fetches eleven bundle paths in
page, each with a `?compression-probe=670` query so the measurement can never be
confused with the app's own concurrent boot load of the same file, and asserts
two independent things per path: `Content-Encoding` read off
`page.on("response")` — the protocol-level response, not what the renderer
chooses to expose to `fetch()` — and `encodedBodySize < decodedBodySize` from
`PerformanceResourceTiming`, so a header alone can never carry it. (The size has
to come from timings rather than `Content-Length`: on-the-fly gzip makes these
responses chunked, so there is no length header.) It prints the real wire sizes,
which is where #670's and #688's "after" measurements legitimately come from.

Every probe also pins a `Content-Type`, for the same `try_files` reason as
above — and since #688 that pin carries a second job: it is what would catch a
`types {}` block placed in a nested context, which _replaces_ nginx's inherited
MIME map instead of extending it and would collapse every response to
`application/octet-stream` with `nginx -t` green.

Two probes are **negative** controls — a PNG and a `.frag` shader — because
"already-compressed types are excluded" is half the requirement and nginx has no
negative directive to assert against: the `gzip_types` allow-list _is_ the
exclusion mechanism. The second control used to be a `.ttf`, standing for
nginx's `application/octet-stream` `default_type`; #688 gave `.ttf` a real type
and the `.frag` took the role over, because dropping it would leave the spec
unable to tell "octet-stream is excluded" from "octet-stream is listed and
everything is compressed". What this spec structurally cannot see — `text/html`
staying **out** of `gzip_types` — is pinned off-browser by
`client/test/nginx_compression_test.dart`.

**`tests/same-origin-boot.spec.ts`** (#620, NFR-CMP/FR-OF-1/C-2) is the other
spec that logs nobody in. It watches every request a cold, cache-less context makes
while the app boots and first paints, and fails on any host that is neither the
app nor the auth origin. It exists because CanvasKit fetched Roboto from
`fonts.gstatic.com` on every cold load — the engine downloads a default family,
whose name it hardcodes, whenever `FontManifest.json` declares none, and
`--no-web-resources-cdn` does **not** suppress that. Only a real browser against
the real bundle can prove the request is gone.

Note what each half is good for. This spec proves the **outcome** ("nothing left
the origin"), and it is also the only thing in CI that would notice
`--no-web-resources-cdn` being dropped from a build command. It does **not**
distinguish the two settings that produce that outcome — the engine builds its
Roboto URL on the same `fontFallbackBaseUrl` the bootstrap pins, so deleting the
bundled family from `pubspec.yaml` would keep this spec green.
`client/test/fonts_local_fallback_test.dart` is what pins each setting, and it
runs in the fast gate. The second test here covers what the Dart one cannot see:
that the deployed bundle really carries the pinned config, and that nginx answers
`/font-fallback/…` with a **404** rather than the SPA's index.html (which the
engine would download in full and then fail to parse as a font).

Because it asserts an _absence_, it also asserts two presences first — the font
manifest and the bundled Roboto were both actually fetched — so a boot that died
before loading fonts fails loudly instead of passing with an empty list.

**`tests/map-tiles-csp.spec.ts`** (#671, NFR-SEC-1/FR-AP-3/D-16) logs nobody in
either, and it is the only spec that makes the CSP **enforcing**. `flutter_map`
fetches tiles through `package:http` — an `XMLHttpRequest` on web — so a tile is
governed by `connect-src`, not `img-src`, and `connect-src` named neither tile
host until #671. Report-Only hid that completely: nothing blocks, so the map
kept working and would have gone blank in three screens at once the day #462
flips the header name. So this spec reads the policy the PWA container
**actually ships**, re-serves a document from the app's own origin carrying that
exact string under the enforcing header name, and makes the browser decide —
the deployed policy, enforced, against the image built from the commit under
test.

It deliberately does not drive the Flutter map: every map view is behind an OIDC
login, six widget tests already cover the rendering, and the property in
question is whether the browser permits the request `flutter_map` makes, which
this spec issues directly. Every third-party URL is `page.route`-stubbed, so
nothing reaches Esri or the OSM Foundation from a runner — and that interception
is also the mechanism, because a CSP-blocked request never reaches the network
layer at all. Two guards keep it from passing vacuously: it first proves the
deployed `main.dart.js` really references both tile origins, and it ends on a
negative control (`fonts.gstatic.com` must be refused with a `connect-src`
violation), without which a policy that failed to apply would satisfy every
other assertion. `client/test/map_tile_csp_test.dart` is the seconds-long half —
it holds `connect-src` against the constants the three map screens pass to
`TileLayer`, in both directions, so the two cannot drift apart.

**`tests/offline-boot.spec.ts`** (#619, FR-OF-1/FR-PL-1/NFR-PER-1/D-10) is the
fourth login-free spec, and the only one that runs **with** service workers:
`playwright.config.ts` blocks them suite-wide and this file opts back in with
`test.use({ serviceWorkers: "allow" })`. It boots the app online, then takes the
browser genuinely offline, reloads, and asserts the **shell renders** — the
login screen's Sign in button, not merely a 200.

The suite-wide block is not incidental. The app-shell worker answers every
bundle path out of the Cache API, and `cache: "no-store"` is an HTTP-cache
directive that does **not** bypass a service worker — so a controlled page would
let `cache-headers.spec.ts` measure Cache Storage while believing it measured
nginx, and pass, because a stored response keeps the headers it was stored with.
Blocking by default also spares every other spec a full precache per context on
a k3d runner.

An offline test is an absence assertion, so this one asserts its way in: the
registration exists and is **ours** (Flutter's self-unregistering stub claims the
same `/` scope, which is the #619 bug), exactly one `bkit-app-shell-*` cache
exists **and the decoy caches it seeded before anything registered are gone** (a
plain "one cache" check is true of a fresh profile whether or not the sweep runs;
the decoys are what turn the eviction half into an observation), that cache holds
**named** entries (`index.html`, `main.dart.js`, the fonts, `sqlite3.wasm`,
PowerSync's worker) plus the CanvasKit variant this browser actually booted —
that one is stored lazily, because the build ships six mutually exclusive
variants and only the browser knows which it wants, and it is **polled** rather
than read once because `sw_register.js` warms it asynchronously. Then **two
negative controls**: a same-origin path the worker never handles must answer 200
online and **reject** offline (the page's own network is really off), and a path
the worker _does_ handle but has not cached must reject too (the **worker's own**
`fetch` is really off — otherwise a cache miss could be quietly served from the
network and the offline half would prove much less than it claims). The offline
reload goes to a **deep link**, since offline only the worker's navigation branch
can answer one, and it also asserts `crossOriginIsolated`, which is only true if
the _cached_ document still carries nginx's COOP/COEP — without it PowerSync's
wasm/OPFS worker cannot start, so the app would come back offline and then never
sync.

It also pins the release-invalidation mechanism: nothing `flutter build web`
emits is content-hashed (#678), so `client/tool/build_app_shell_cache.dart`
injects a per-file sha-256 into the worker at build time and the cache name is
derived from all of them. The spec hashes the bytes nginx serves for
`/index.html` and `/main.dart.js` — from a second, service-worker-**blocked**
context, so it measures the wire rather than the cache those revisions filled —
and checks they match the revisions the deployed worker embeds. Any changed byte
therefore changes the worker script the browser update-checks, and the decoy
assertion above shows what that produces.
`client/test/tool/build_app_shell_cache_test.dart` is the behavioural half (flip
a byte, assert the revision moves) and
`client/test/app_shell_service_worker_test.dart` pins the `web/` wiring.

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

## Static checks (run in `task ci`, no cluster needed)

Running this suite needs a deployed slice and a browser, so `taskfiles/web.yml`'s package fan-out
skips `*/e2e/*` — but **typechecking and format-checking it need neither**, and Playwright's own
transform strips types _without_ checking them, so before #696 a type error here surfaced (if at
all) as a runtime failure inside a browser against a real cluster, 40-60 minutes into `helm-e2e`.

`npm run lint` (= `tsc --noEmit` + `prettier --check`) is that gate. `task web:e2e-lint` runs it
from the repo root — reached by `task lint`, so by `task ci` on every PR — installing this
package's `node_modules` but **not** the browsers. `npm run format` writes the Prettier fixes.
[`tsconfig.json`](tsconfig.json) is typecheck-only (nothing emits); it carries `@types/node` for
the `process`/`Buffer`/`node:crypto` uses here, and `lib: DOM` for the browser globals inside
`page.evaluate` bodies.

> If `task lint` fails here with `tsc: not found`, your `node_modules` predates #696 — the
> taskfile only runs `npm ci` when the directory is **absent**. `rm -rf node_modules && npm ci`.

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
