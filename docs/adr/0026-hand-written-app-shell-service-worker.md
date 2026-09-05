# 0026 — A hand-written app-shell service worker, invalidated by a build-time content revision

- **Status:** Accepted
- **Date:** 2026-09-04
- **Issue / Epic:** #619 · M22 (H1 · Offline shell restored) · regression against #93 · blocks #678, #233
- **Requirements:** FR-OF-1, FR-PL-1, NFR-PER-1, NFR-TST-1, NFR-CMP
- **Decisions:** [D-10](../../requirements/decisions.md#d-10--platform-rollout-pwa--android--ios-native-only-when-needed)
  (PWA first), [C-2](../../requirements/context.md#c-2--portugal-first)
- **As built:** [`docs/client/pwa-installability.md` §3](../client/pwa-installability.md)

## Context

FR-OF-1 says the app is used mainly in the field and must work offline. D-10 makes the installable
PWA the first surface. #93 shipped that on the assumption that Flutter's build generates a
caching service worker — which it did, once.

It does not any more. Since [flutter/flutter#156910](https://github.com/flutter/flutter/issues/156910)
the generated `flutter_service_worker.js` is an 815-byte **deprecation stub**: `install` calls
`skipWaiting()`, `activate` calls `self.registration.unregister()` and reloads every client. No
`RESOURCES` manifest, no `caches.open`, no `fetch` handler. Its only job is to remove a worker an
older Flutter installed. So the deployed app ended every load with zero registrations and zero
caches, and could not start without a connection.

It went unnoticed for a release because nothing was looking: the e2e suite always ran online, and
the Lighthouse installability audit checks that a worker is _registered_, not that it caches
anything (and Chrome has since dropped the worker requirement from installability altogether).

Two constraints shape any fix:

- **No third-party origin may be on the boot path.** `client/e2e/tests/same-origin-boot.spec.ts`
  fails on any request leaving the deployment's own origins (#620, NFR-CMP, C-2), and
  `client/nginx.conf` ships `script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'`.
- **Nothing `flutter build web` emits is content-hashed.** `main.dart.js`,
  `flutter_bootstrap.js`, `canvaskit/*`, `sqlite3.wasm`, `powersync_db.worker.js` and the
  tree-shaken `MaterialIcons-Regular.otf` are stable names whose bytes change every release, and
  `version.json` carries only pubspec's version, which does not move per commit. Fingerprinting
  the filenames is #678, which this issue blocks.

## Decision

**1. Own the worker.** `client/web/service_worker.js` is hand-written and dependency-free,
registered from `client/web/index.html` through `client/web/sw_register.js`.
`client/web/flutter_bootstrap.js` drops `serviceWorkerSettings` so Flutter's loader never
registers the stub — a registration is keyed by scope, and the stub would take the same `/` scope
and unregister our worker back out of it.

**2. Invalidate on a build-time content revision, not a filename.**
`client/tool/build_app_shell_cache.dart` runs after every `flutter build web` and injects, into
the marked region of the worker, a sha-256 per file plus a `BUILD_REVISION` derived from all of
them — **and from `client/nginx.conf`**. This changes the **worker script's own bytes** every
release, which is precisely what the browser's service-worker update check compares. A new build
therefore yields a new worker, a new `bkit-app-shell-<BUILD_REVISION>` cache, and the deletion of
every older one. The manifest is injected into the script rather than `importScripts`ed so the
update check does not have to reach through a subresource.

`nginx.conf` is in that digest because the worker stores responses **as received**: an installed
client keeps serving the document with the headers captured when its build installed. Without it,
a release that changes only a header would leave the worker byte-identical, fire no update check,
and never reach an installed client — indefinitely. #89, flipping the CSP from Report-Only to
enforcing, is exactly such a release.

**3. Two tiers.** The boot path (~6.6 MB) is precached during `install`. The CanvasKit engine,
`assets/NOTICES` and `assets/AssetManifest.bin.json` are stored lazily. The build ships six
mutually exclusive CanvasKit variants (~38 MB) of which a browser downloads exactly one pair;
`install` has no browser to ask, so precaching them all would make every release a ~46 MB
all-or-nothing download on the mobile connections FR-OF-1 and C-2 are about (NFR-PER-1).

"Lazily" needs one more mechanism than a fetch handler, and this is the least obvious part of the
design. On a first visit the worker is registered at `load` and then spends seconds precaching, so
by the time it activates and claims the page the engine has **already** fetched its variant, with
no worker in the way — a user who visits once and drives out of signal would find an app with no
engine to paint with. (Confirmed empirically: with the fetch handler alone,
`client/e2e/tests/offline-boot.spec.ts` fails on exactly that.) So `client/web/sw_register.js`
reports what the page actually loaded (`performance.getEntriesByType("resource")`) to the worker
that **controls** the page, and re-reports on every `controllerchange` — the update path matters
just as much, since a new worker's cache is otherwise engine-less until the visit after next. The
report is treated as an untrusted hint: a reported URL is fetched only if it is same-origin and
already in that build's `RUNTIME` manifest.

**4. Handle only the shell.** `respondWith` is called only for navigations to client-side routes
and same-origin GETs listed in the manifest. Everything else — the domain APIs, the PowerSync
sync stream, OIDC traffic, non-GET, ranged and cross-origin requests — falls through with no
`respondWith` at all, so no response carrying org data is written to a cache the worker controls,
and streaming/credentials behave exactly as with no worker installed.

"Client-side routes" is narrower than "every navigation", deliberately. The worker's scope is the
whole origin, and the gateway routes `/v1/*` and `/sync-stream` on this host to backend services
before nginx ever sees them — so answering those from the cached `index.html` would be wrong.
`SERVER_ROUTED_PREFIXES` excludes them. Nothing in the app navigates to one today (every API call
is `fetch`), but a downloaded export or a presigned-object redirect would.

That list is a hand-maintained mirror of the gateway chart, and a route added there without it
would fail **silently** — `helm lint` green, pod Ready, every `fetch` still correct.
`scripts/check-service-worker-routes.sh` (#683, in `task lint`) therefore reads the array out of
the worker and the `routes`/`powersyncRoute` out of
`infra/helm/beekeepingit/charts/gateway/values.yaml` and fails when they disagree in either
direction. It scopes itself to the **app host** (`authRoutes`/`adminRoutes` are other origins the
worker's scope never covers) and skips the routes served by the `/` catch-all's own Service, which
is what nginx answers and what the cached shell is a correct reply for.

A response is also refused if it is not really the asset it was asked for: nginx's
`try_files $uri $uri/ /index.html` answers **any** miss with 200 + the HTML document, so
`response.ok` alone would let a moved asset precache the shell document under every asset path —
an install that succeeds and then boots offline into nothing.

## Consequences

- The app starts with no connection. Offline **data** remains PowerSync's local-first store
  (`EPIC-06`); this is only the shell.
- Cached responses are stored **as received**, headers included, so the cached `index.html` still
  carries nginx's COOP/COEP and an offline boot is still cross-origin isolated — without which
  `SharedArrayBuffer`, and therefore PowerSync's wasm/OPFS worker, would not start.
- A release lands one page load late: the navigation that discovers the new worker is still
  served the old shell, and the next load is the new build. `skipWaiting()`/`claim()` keep that to
  one load rather than "until every tab is closed", which on an installed PWA can be days.
- The cost of that: a page still running the old build can be handed a newer asset for a stable
  name. That is byte-for-byte what nginx already does with `Cache-Control: no-cache` and no worker
  at all, so it is not a regression — #678 (content-hashed filenames) closes it properly.
- The bundle must be hashed **after** the build, so `flutter build web` alone is no longer a
  complete client build. That duplication across four build sites is guarded by
  `scripts/check-app-shell-precache-wired.sh` in `task lint`. A build that skips the generator
  ships an **inert** worker (it caches nothing and handles no fetch) rather than a broken one.
- `client/e2e` now blocks service workers by default. Without that, `cache-headers.spec.ts` would
  measure Cache Storage while believing it measured nginx — and still pass, since a cached
  response keeps the headers it was stored with.
- Caches left behind by the Flutter-generated worker (`flutter-*`) are swept once, here. Its stub
  unregisters itself but never deletes what it stored, and those bytes compete for the quota this
  feature now needs.
- **An XSS on the app origin is worth more than it was.** A worker at `/` scope means script
  execution on this origin can persist itself across reloads and offline use. `nginx.conf` still
  ships its CSP as `Content-Security-Policy-Report-Only`, so `script-src 'self'` is not actually
  enforced today. That was already worth fixing; #89 is now worth more than it was before this
  merged.

## Alternatives

- **Keep Flutter's worker.** Not available: it caches nothing by design and removes itself.
- **Vendor Workbox.** It would satisfy the same-origin and CSP constraints if bundled rather than
  loaded from a CDN, and `injectManifest` is the exact pattern used here. Rejected because the
  behaviour needed is a precache plus cache-first, the whole worker is ~100 lines, and a service
  worker sits in front of every request the app makes — "small enough that a reviewer reads all of
  it" is a security property, not a style preference. Revisit if runtime-caching strategies
  multiply.
- **Key the cache on `version.json` or the git SHA.** `version.json` does not move per commit. A
  SHA would work but would make the worker's cache identity independent of its actual contents, so
  a rebuild of the same commit with a different Flutter would silently reuse a stale shell. The
  content revision is the honest key, and it is testable.
- **Generate the manifest in `client/Dockerfile`.** One site instead of four, and drift-proof.
  Rejected: that image "only COPYs the prebuilt artifact" by explicit convention (its own header,
  `admin/Dockerfile`, `build-publish.yml`), it would make the generator untestable, and it would
  leave `flutter run` / a plain `flutter build web` with no offline shell to exercise — the
  developer loop the manual pass in `pwa-installability.md` depends on.
- **Precache everything, including all six CanvasKit variants.** Simplest rule, and what Flutter's
  old worker did. Rejected on NFR-PER-1: ~46 MB, atomically, on a field connection, and a single
  failed fetch leaves the user with no worker at all.
- **Defer the old-cache sweep while a page from the previous build is open.** Narrows the
  mixed-build window, but nothing would ever reopen to finish the job, so every release would
  leave its shell behind until the origin's storage quota is hit — and a quota failure breaks
  `install` outright, costing the offline shell entirely.
