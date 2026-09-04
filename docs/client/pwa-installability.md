# PWA installability — audits & manual verification

**Issue:** #93 · **Requirements:** FR-PL-1 · **Decisions:** [D-10](../../requirements/decisions.md) (PWA-first)

Documents how BeekeepingIT's installability (add-to-home-screen + offline app-shell) is
verified: the automated Lighthouse CI gate, the automated **offline-boot** e2e, and the manual
pass neither can cover (an audit checks the manifest is _present and well-formed_, not that a
real browser actually offers the install prompt).

> **Note on the audit's scope.** Chrome dropped the service-worker requirement from PWA
> installability, and `installable-manifest` does not inspect caching. That is precisely why the
> app could ship for a release with **no** app-shell cache and every gate stay green (#619) — the
> offline half is now covered by `client/e2e/tests/offline-boot.spec.ts` (§3), not by Lighthouse.

## 1. Automated audit (CI)

`client/lighthouserc.json` runs [Lighthouse CI](https://github.com/GoogleChrome/lighthouse-ci)
(`@lhci/cli`, pinned `0.13.0`) against the built `client/build/web` artifact, as a step in the
`build` job of [`.github/workflows/build-publish.yml`](../../.github/workflows/build-publish.yml)
(`if: matrix.component == 'client'`), right after `flutter build web`. It runs on every PR/push
that touches `client/` (the existing path-filtered matrix), using LHCI's own static file server
against the build output — no live cluster or gateway needed.

**Scope — installability only, not full Lighthouse:** `onlyCategories: ["pwa"]` restricts
collection to the PWA category, and the assertions further narrow to the installability-relevant
audits, each required at `minScore: 1`:

| Audit                  | What it checks                                                               |
| ---------------------- | ---------------------------------------------------------------------------- |
| `installable-manifest` | The manifest meets the browser's install requirements                        |
| `viewport`             | A `<meta name="viewport">` tag is present (required for install eligibility) |
| `content-width`        | Content isn't wider than the viewport (part of installability, not perf)     |
| `maskable-icon`        | Manifest has a `purpose: maskable` icon (Android adaptive icon)              |
| `themed-omnibox`       | `<meta name="theme-color">` themes the browser address bar                   |
| `splash-screen`        | Manifest has what's needed for a custom splash screen on launch              |

`is-on-https` is skipped at collection time (`skipAudits`) — Lighthouse can't see the real
gateway's TLS termination when auditing a local static build, and HTTPS hosting is already
covered structurally (the `pwa` Helm chart is only ever reached through the TLS-terminating
ingress; see [`docs/architecture/platform.md`](../architecture/platform.md)), not by this audit.

**Deliberately not gated:** Lighthouse's `performance`, `accessibility`, `best-practices`, and
`seo` categories, and the PWA category's non-installability audits (`pwa-cross-browser`,
`pwa-page-transitions`, `pwa-each-page-has-url` — these assume a multi-page app with URL-bar
navigation, not the primary signal for an installable-manifest check). The goal is a gate that
fails on an installability regression (e.g. someone removes the manifest link, drops the
maskable icon, or deletes `theme-color`), not one that's noisy about unrelated perf/SEO drift.

**Run it locally:**

```sh
cd client
flutter pub get && dart run powersync:setup_web
flutter build web --release --no-web-resources-cdn
npx --yes @lhci/cli@0.13.0 autorun --config=./lighthouserc.json
```

Reports land in `client/lhci-report/` (gitignored).

**Known gap the audit does not catch:** Lighthouse's `maskable-icon` audit only checks that the
manifest _declares_ an icon with `purpose: maskable` at the right sizes — it does not check
whether the artwork is project-branded. Only a human looking at the files can tell you that,
so the audit passing is necessary but not sufficient for the "real project app icons" AC.

That AC (#93, tracked in #233) is **met as of #233**: `client/web/icons/*` and `favicon.png`
carry the Melargil bee mark — a white bee on the brand amber `#F9A825`, which is also the
manifest's `theme_color`/`background_color`, so the icon, the splash screen and the browser
omnibox agree rather than the icon being the odd one out. They are rasterised from the vector
logo master, with the bee isolated from the wordmark by colour, so the set can be regenerated
at any size without losing crispness. The maskable pair insets the bee to ~62% of the canvas so
it survives Android's circle/squircle crop; the plain pair fills ~86%.

## 2. Served caching policy (as built)

The container that serves the built bundle (`client/nginx.conf`, the `pwa` Helm chart) sends
one explicit header for **everything** it serves (#621):

```text
Cache-Control: no-cache
```

`no-cache` is not "don't store" — it is "store, but revalidate before reuse", so nginx's
`ETag`/`Last-Modified` turn repeat loads into cheap `304 Not Modified` responses while a new
release is picked up on the very next load. Before this, no `Cache-Control` was sent at all and
browsers fell back to **heuristic** caching (an implementation-defined freshness guess derived
from `Last-Modified`), which can hold a stale bundle for an unbounded window after a deploy.

**Nothing is served `immutable`, deliberately.** `flutter build web` emits **no content-hashed
filenames**: `index.html`, `main.dart.js`, `flutter_bootstrap.js`, `flutter.js`, `version.json`,
`manifest.json`, `canvaskit/*`, `sqlite3.wasm`, `powersync_db.worker.js`, and the (per-build
tree-shaken) `assets/fonts/MaterialIcons-Regular.otf` are all **stable names whose bytes change
every release**. A long `max-age=…, immutable` therefore has no safe target here — it would pin
users to a stale build with no reload escape. The same missing hashes are the strongest argument
for keeping the policy **uniform**: mixing `no-cache` on the document with any stale-tolerant
policy on the assets could serve a fresh `index.html` against a previous build's cached
`main.dart.js`, and revalidating everything is what keeps a release atomic.

The header is set at **server** level, not inside the SPA-fallback `location {}`: in nginx an
`add_header` inside a `location` cancels inheritance of **every** server-level `add_header`, which
would silently drop COOP/COEP, `X-Content-Type-Options`, `Referrer-Policy` and the Report-Only
CSP (#89).

**`no-cache` does not — and cannot — give an offline reload.** It means a stored response may
not be reused without a **successful** revalidation ([RFC 9111
§5.2.2.4](https://www.rfc-editor.org/rfc/rfc9111#section-5.2.2.4)), and with no connectivity that
revalidation fails, so the browser has nothing it is allowed to serve. Under the previous
no-header state, heuristic freshness could sometimes let a repeat visit paint without the
network — accidentally, and just as easily with a stale build. So this header makes repeat loads
cheap and releases prompt; the offline shell is the service worker's job (§3), and #619 was a
**hard prerequisite** for FR-PL-1's offline app-shell AC rather than merely the next thing after
this. Both issues sit in the same milestone (H1 · Offline shell restored).

Verified live by `client/e2e/tests/cache-headers.spec.ts` through the gateway, from the real
nginx container, in the `helm-e2e` job. That spec runs with service workers **blocked**
(`playwright.config.ts`) so it keeps measuring what nginx put on the wire rather than what the
worker stored.

## 2b. Compression (as built)

The same container compresses the bundle on the fly (#670, `NFR-PER-1`, `FR-OF-1`, `C-2`).
Before this, nothing in the serving path did: `nginx.conf` never enabled `gzip`, the
`nginx:1.31-alpine` base ships it commented out in its own config, and Traefik has no compress
middleware — so the two biggest files went over the wire whole on every cold load, and again after
every release invalidated the shell.

| Asset                               |       Before |       After | Saved |
| ----------------------------------- | -----------: | ----------: | ----: |
| `main.dart.js`                      |  4,441,974 B | 1,458,316 B | 67.2% |
| `canvaskit/chromium/canvaskit.wasm` |  5,760,502 B | 2,401,322 B | 58.3% |
| Both, as a cold load pays them      | 10,202,476 B | 3,859,638 B | 62.2% |

The directives are `gzip on; gzip_proxied any; gzip_vary on; gzip_comp_level 2;
gzip_min_length 256;` plus a `gzip_types` allow-list, all at **server** level. `text/html` is
absent from that list deliberately — nginx always compresses it, and listing it logs a
duplicate-MIME warning.

**Level 2 is a CPU decision, not a compression one.** The `pwa` Deployment is one replica, no HPA,
100m CPU in dev and staging, with its liveness/readiness probes in the same cgroup — and gzip ends
`sendfile` for these responses, so this is the pod's first real CPU load. It arrives all at once,
because this file's bytes feed `BUILD_REVISION` and a release therefore re-primes every installed
shell simultaneously. Level 2 captures **94%** of the bytes level 9 could (level 9 would take
`main.dart.js` to 1,248,305 B and the `.wasm` to 2,185,812 B), for a small fraction of the work.
Raising it is a one-line change the day that pod is sized for it — **#693** tracks measuring it live.

One knock-on worth knowing: nginx weakens the `ETag` to `W/"…"` on every compressed response and
drops `Content-Length`/`Accept-Ranges`. The 304s §2 relies on still happen (`If-None-Match` compares
weakly), and so does the service worker's cheap re-precache, but the strong ETag §2 names is no
longer what they rest on.

**On-the-fly, not `gzip_static`.** Pre-compressed `.gz` twins are usually the better trade for
files that are byte-identical per request, and they are rejected here for a specific reason:
`client/tool/build_app_shell_cache.dart` walks every file under `build/web` and precaches each one,
so a `.gz` beside each asset would make every install download the shell twice. Generating them
inside `client/Dockerfile` would dodge that but break the invariant that image and
[ADR-0026](../adr/0026-hand-written-app-shell-service-worker.md) both state — it only COPYs the
prebuilt artifact — and would leave a silent ordering dependency in its place. The runtime cost is
bounded: `no-cache` turns repeat loads into bodiless 304s, and the service worker precaches once
per release. No Brotli — `ngx_brotli` is not in the official image, and #670 scoped Brotli to
whatever the base image supports without a custom build.

**What is still uncompressed, and why.** The allow-list _is_ the exclusion mechanism; there is no
negative directive. `image/png` and `font/woff2` are already-compressed formats and are simply
never named. `application/octet-stream` is unnamed for a sharper reason — it is nginx's
`default_type`, so listing it would sweep in every unrecognised file, PNGs included. The cost is
that the bundled font faces (461 KB, precached, ~46% compressible) and `assets/NOTICES` (1.45 MB,
runtime-tier, 89% compressible) still transfer whole, because the stock `mime.types` has no
`.ttf`/`.otf` entry and `NOTICES` has no extension at all. That is tracked on **#688**; the fix is
a MIME mapping, and a `types {}` block inside this `server {}` would _replace_ the inherited map
rather than extend it.

**This change necessarily re-primes every installed shell**, because `nginx.conf`'s bytes feed
`BUILD_REVISION` (§3). That is required rather than incidental: the worker stores responses as
received, so installed clients would otherwise keep serving themselves uncompressed-era responses
indefinitely.

Verified live by `client/e2e/tests/compression.spec.ts` in the same `helm-e2e` job — protocol-level
`Content-Encoding` from `page.on("response")`, plus `PerformanceResourceTiming`'s
`encodedBodySize`/`decodedBodySize` so the saving is measured rather than inferred, and two
negative controls (a PNG and a `.ttf`) for the exclusions. What no live probe can see —
`text/html` and `application/octet-stream` staying **out** of `gzip_types` — is pinned off-browser
by `client/test/nginx_compression_test.dart`.

## 3. App-shell service worker (as built)

`client/web/service_worker.js` is this repo's own, hand-written and dependency-free, registered
from `client/web/index.html` via `client/web/sw_register.js` (#619). The decision and the
alternatives weighed are [ADR-0026](../adr/0026-hand-written-app-shell-service-worker.md); this
section is what it looks like as built.

**Why not Flutter's.** Flutter's generated `flutter_service_worker.js` has been a
self-unregistering deprecation stub since
[flutter/flutter#156910](https://github.com/flutter/flutter/issues/156910): `install` calls
`skipWaiting()`, `activate` calls `self.registration.unregister()` and reloads every client. It
caches nothing. `client/web/flutter_bootstrap.js` therefore no longer passes
`serviceWorkerSettings`, so Flutter's loader never registers it — a registration is keyed by
**scope**, and the stub would otherwise take the same `/` scope and unregister our worker back
out of it.

**Why hand-written.** No Workbox, no CDN: `client/e2e/tests/same-origin-boot.spec.ts` fails on
any request leaving the deployment's origins (#620), and `nginx.conf` ships
`script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'`. A worker also sits in front of every
request the app makes, so "small enough to read in full" is a security property.

**What it caches.** Only same-origin GETs for paths in its build-time manifest, plus navigations
(served the cached `index.html`, exactly as nginx's SPA fallback would). Everything else — the
domain APIs, the PowerSync sync stream, OIDC traffic, non-GET, cross-origin — is left untouched
with no `respondWith` at all, so no response carrying org data is ever written to a cache the
worker controls. Offline **data** is PowerSync's local-first store (`EPIC-06`), a separate
mechanism.

Two tiers, because the shell is not small:

| Tier                  | Contents                                                                                           | Size                |
| --------------------- | -------------------------------------------------------------------------------------------------- | ------------------- |
| Precached (`install`) | `index.html`, `main.dart.js`, the loader scripts, fonts, icons, `sqlite3.wasm`, PowerSync's worker | ~6.6 MB             |
| Stored lazily         | `canvaskit/*`, `assets/NOTICES`, `assets/AssetManifest.bin.json`                                   | ~5.9 MB in practice |

The build ships **six mutually exclusive CanvasKit variants** (~38 MB) of which a browser
downloads exactly one pair. `install` has no browser to ask, so precaching them all would make
every release a ~46 MB all-or-nothing download for a beekeeper on mobile data (`NFR-PER-1`).

**How the lazy tier is filled is the least obvious part of the design.** A fetch handler alone
does not do it: on a first visit the worker is registered at `load` and then spends seconds
precaching, so by the time it activates and claims the page the engine has already fetched its
variant with no worker in the way — and nothing re-requests it. `client/web/sw_register.js`
therefore reports what the page loaded (`performance.getEntriesByType("resource")`) to the worker
that **controls** it, and re-reports on every `controllerchange` — the update path needs it too,
since a new build's cache would otherwise be engine-less until the visit after next. The worker
treats the report as an untrusted hint and stores only paths already in that build's `RUNTIME`
manifest.

**Only client-side routes are answered from the shell.** The worker's scope is the whole origin,
and the gateway routes `/v1/*` and `/sync-stream` on this host to backend services before nginx
sees them, so those are excluded from the navigation branch. A response is also refused if it is
not really the asset it was asked for — `try_files $uri $uri/ /index.html` answers any miss with
200 + the HTML document, so `response.ok` alone would precache the shell under every asset path.

**How a release invalidates the shell.** Nothing `flutter build web` emits is content-hashed
(#678), so a filename can never be the cache key. `client/tool/build_app_shell_cache.dart` runs
after every build and injects a sha-256 per file plus a `BUILD_REVISION` over all of them into
the worker. That changes the **worker script's own bytes** on every release, which is exactly
what the browser's service-worker update check compares — so a new build yields a new worker, a
new `bkit-app-shell-<BUILD_REVISION>` cache, and the deletion of every older one (plus any
`flutter-*` cache the Flutter-era worker left behind). The swap costs one page load
(`skipWaiting()`/`claim()` keep it to one instead of "until every tab is closed").

`nginx.conf`'s bytes feed that revision too, and must: the worker stores responses **as
received**, so an installed client keeps serving the document with the headers captured when its
build installed. A release that changes only a header would otherwise leave the worker
byte-identical and never reach an installed client. **#89 is exactly such a release** — flipping
the CSP from Report-Only to enforcing has to go out with a rebuilt shell, which this makes
automatic.

Skip that generator step and the worker ships **inert**: it installs, caches nothing, handles no
fetch, and the app silently cannot start offline again. `scripts/check-app-shell-precache-wired.sh`
(in `task lint`) fails if any `flutter build web` site loses it.

**Covered by:** `client/test/app_shell_service_worker_test.dart` (the `web/` wiring),
`client/test/tool/build_app_shell_cache_test.dart` (the invalidation mechanism — flip a byte,
the revision moves), and `client/e2e/tests/offline-boot.spec.ts` (a real browser, genuinely
offline, against the deployed image, asserting the shell **renders**).

## 4. Manual pass — install + offline-shell-serving

The audits above prove the manifest is well-formed; they do not prove a real browser actually
shows the install prompt or that installing produces a working standalone app. That needs a real
device.

**The offline half is no longer manual.** It was blocked on #619 and would have failed
deterministically; it is now an automated check —
`client/e2e/tests/offline-boot.spec.ts`, run in `helm-e2e` against the real deployed image (§3).
What remains here is what only a person with a device can do. The items below are kept as the
historical record, annotated where the record turned out to be wrong.

### What was verified in this pass (static build inspection — no live cluster)

Done as part of this change, against the built `client/build/web` artifact and source
templates, without a live gateway/cluster:

- [x] `manifest.json` is valid JSON with `name`, `short_name`, `start_url`, `display: standalone`,
      `theme_color`, `background_color`, and both a `192x192`/`512x512` icon pair and a
      `maskable` pair, at the declared sizes — confirmed via the Lighthouse
      `installable-manifest`/`maskable-icon` audits against the real asset files (§1). The
      artwork is the Melargil bee brand mark as of #233 — see the callout in §1.
- [x] `index.html` links the manifest (`<link rel="manifest">`), sets `theme-color` and
      `viewport` meta tags (both were missing before this change — added, see the PR diff),
      and carries the iOS-specific meta tags/`apple-touch-icon` for Safari's non-standard
      install path.
- [x] ~~Flutter's build (`flutter build web`) generates a service worker
      (`flutter_service_worker.js`) that precaches the app shell (engine/framework JS, fonts,
      the manifest, the icons) — this is Flutter's own web-build behavior, not custom code
      here; confirmed by reading the generated `build/web/flutter_service_worker.js` manifest
      list structure in a local build.~~ **The original claim was wrong** and is struck through
      rather than deleted, so the belief this pass acted on stays visible. On the pinned Flutter
      (3.44) the generated `flutter_service_worker.js` is a **self-unregistering deprecation
      stub**: it calls `self.registration.unregister()` on activate, so it precaches nothing and
      removes itself. Ticked now because the property is finally true — by **custom code here**,
      not by Flutter: `client/web/service_worker.js` precaches the shell and
      `client/tool/build_app_shell_cache.dart` gives it a per-release cache key (§3, #619).
- [x] The `pwa` Helm chart (`infra/helm/beekeepingit/charts/pwa/`) serves the static bundle
      (`client/Dockerfile` + `nginx.conf`) behind the cluster's TLS-terminating ingress — HTTPS
      is a deployment property of the chart, not something a static-file Lighthouse run can
      itself confirm (§1's `is-on-https` skip).

### What still needs a human device pass

Needs a person with a real Chrome/Android session against a **deployed** (or `flutter run -d
chrome`-served) instance — not reproducible from a static build in this environment:

- [x] **Chrome desktop/Android install prompt** — open the hosted URL (or
      `flutter run -d chrome` locally), confirm Chrome's install affordance (omnibox icon /
      "Add to Home screen" menu item on Android) appears, and that accepting it installs a
      standalone-windowed app with the BeekeepingIT icon and name. **Passed** — see the pass log
      below.
- [x] **Offline app-shell serving in an INSTALLED app.** The browser-tab half of this is no
      longer manual: `client/e2e/tests/offline-boot.spec.ts` does exactly it — go offline, reload
      (at a deep link), assert the shell renders — in a real Chromium against the real deployed
      image, on every PR touching `client/**`, `infra/helm/**` or `infra/cluster/**`. What is
      still open is the **installed standalone window on a real device**, which is a different
      client context from a tab and is not something CI can produce: install from Android Chrome,
      switch on airplane mode, launch from the home screen, confirm the shell paints (a blank
      screen or the offline-dino page is a fail). Per the issue's scope note it checks the
      **shell** loads, not that data/API calls work offline — that's PowerSync's local-first sync
      (`EPIC-06`), covered elsewhere.
- [x] **Large-device no-offline-requirement check (FR-PL-1)** — on a laptop/desktop viewport,
      confirm the app functions normally online; desktops are not required to pass the offline
      check above, only phones/tablets are.

### Pass log

| Field                         | Result                                                                                                             |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Date                          | 2026-09-04                                                                                                         |
| Build under test              | `v0.0.1-rc16` on staging (`https://beekeepingit-rc.melargil.pt`)                                                   |
| Platforms                     | Windows 11 desktop Chrome · Android Chrome                                                                         |
| Install prompt                | **Pass** — offered on both; accepting installs a standalone-windowed app                                           |
| Installed identity            | **Pass** — window title and taskbar read "BeekeepingIT by Melargil", carrying the bee icon from `icons/Icon-*.png` |
| Offline launch, installed app | **Pass** — launched from the home screen with the network off and the shell painted                                |
| Large-device online check     | **Pass** — desktop behaves normally online                                                                         |

**Outcome: pass on every item.** This closes #233 and, with it, the last manual gap in #93's
installability criteria.

One caveat worth carrying forward, because it will look like a failure to the next person who
tests it: the **first** load after a deploy is the one that installs the worker and fills the
cache, so an install-then-immediately-offline sequence on a browser that has never loaded the
app fails by design. Reload once online before testing offline. The automated
`offline-boot.spec.ts` handles this by asserting its online preconditions before it cuts the
network.

Record the result of any later pass the same way (pass/fail + browser/OS versions used); this
doc is the procedure, not a substitute for running it.
