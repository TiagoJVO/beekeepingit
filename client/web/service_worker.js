/*
 * BeekeepingIT's app-shell service worker (#619, FR-OF-1, FR-PL-1, NFR-PER-1, D-10).
 * Decision + alternatives: docs/adr/0026-hand-written-app-shell-service-worker.md
 *
 * WHY THIS FILE EXISTS AT ALL
 * ---------------------------
 * Flutter used to generate a caching worker; it does not any more. Since
 * flutter/flutter#156910 the generated `flutter_service_worker.js` is an
 * 815-byte DEPRECATION STUB: `install` calls `skipWaiting()`, `activate` calls
 * `self.registration.unregister()` and then reloads every client. It exists
 * only to REMOVE a worker an older build installed. It has no RESOURCES
 * manifest, no `caches.open` and no `fetch` handler, so from the release it
 * shipped in the field app had zero registrations and zero caches and could not
 * start without a network connection — a regression against #93's offline
 * app-shell criterion. `client/web/flutter_bootstrap.js` therefore no longer
 * passes `serviceWorkerSettings`, so Flutter's loader never registers that stub
 * (it would otherwise claim this same `/` scope and unregister itself back out
 * of it), and `client/web/sw_register.js` registers THIS file instead.
 *
 * WHY IT IS HAND-WRITTEN
 * ----------------------
 * No Workbox, no library, no CDN. `client/e2e/tests/same-origin-boot.spec.ts`
 * fails if ANY request leaves the deployment's own origins during boot (#620,
 * NFR-CMP, C-2), and `client/nginx.conf` ships
 * `script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'`. Vendoring a
 * library would satisfy both, but the whole behaviour this app needs is a
 * precache plus cache-first, and a service worker sits in front of EVERY
 * request the app makes — "small enough that a reviewer can read all of it" is
 * a security property here, not a style preference.
 *
 * WHAT IT CACHES, AND WHAT IT DELIBERATELY DOES NOT TOUCH
 * ------------------------------------------------------
 * Only the static app shell `flutter build web` emitted, and only same-origin
 * GETs whose pathname is in this build's manifest. It NEVER calls `respondWith`
 * for anything else: the domain APIs, the PowerSync sync stream, OIDC traffic,
 * non-GET requests and every cross-origin request are left to the browser
 * untouched, so no response carrying org data is ever written to a cache this
 * file controls (offline DATA is PowerSync's local-first store, EPIC-06 — a
 * separate mechanism entirely). Passing them through by NOT handling them,
 * rather than by proxying them through `fetch()`, also keeps streaming, range
 * requests and credentials behaving exactly as they do with no worker
 * installed.
 *
 * HOW A NEW RELEASE INVALIDATES THE SHELL
 * ---------------------------------------
 * Nothing `flutter build web` emits is content-hashed (#678): `main.dart.js`,
 * `flutter_bootstrap.js`, `canvaskit/*`, `sqlite3.wasm` and the tree-shaken
 * `MaterialIcons-Regular.otf` are STABLE names whose bytes change every
 * release, so a filename can never be the cache key. Instead
 * `client/tool/build_app_shell_cache.dart` rewrites the marked region below at
 * build time with a sha-256 `revision` per file and a `BUILD_REVISION` derived
 * from all of them together — plus a digest of `client/nginx.conf`, because the
 * cached document carries the headers it was fetched with (see the `cache.put`
 * note), so a header-only release has to invalidate the shell too. Those
 * revisions are not compared at runtime; their job is upstream of that. They
 * make THIS SCRIPT'S OWN BYTES a function of the shell's bytes, and the
 * script's bytes are precisely what the browser's service-worker update check
 * compares. So any change yields a new worker, which opens a new
 * `bkit-app-shell-<BUILD_REVISION>` cache and deletes every older one. The
 * manifest is injected INTO this file rather than `importScripts`ed for the
 * same reason: the update check must not have to reach through a subresource.
 *
 * The swap costs one page load. The navigation that discovers the new worker is
 * still served the old shell (cache-first), the new worker installs behind it,
 * and the NEXT load is the new build. `skipWaiting()`/`claim()` are what keep
 * that to one load instead of "until every tab of the app is closed", which on
 * an installed PWA can be days. Their well-known cost is that a page still
 * running the old build can be handed a newer asset for a stable name; that is
 * byte-for-byte what nginx already does today with `Cache-Control: no-cache`
 * and no worker at all, so it is not a regression, and content-hashed filenames
 * (#678, which this issue blocks) are what actually close the window.
 */

// The manifest is machine-generated: everything between these two markers is
// REPLACED by client/tool/build_app_shell_cache.dart. The values below are the
// inert defaults a raw `flutter build web` keeps — see `isBuilt`.
//
//   PRECACHE  downloaded during `install`; the app cannot boot without them.
//   RUNTIME   stored on first use instead (see the message handler below).
//
// __APP_SHELL_MANIFEST_START__
const BUILD_REVISION = "unbuilt";
const PRECACHE = [];
const RUNTIME = [];
// __APP_SHELL_MANIFEST_END__

// One cache per build. The prefix is what `activate` sweeps, so every older
// build's shell is deleted the moment a new worker takes over.
const CACHE_PREFIX = "bkit-app-shell-";
const CACHE_NAME = CACHE_PREFIX + BUILD_REVISION;

// Caches left behind by the Flutter-generated worker this one replaces. Its
// stub unregisters itself but never deletes what earlier versions stored, so
// those bytes sit in the origin's quota forever — the same quota this worker
// now needs. Swept once, here, since nothing else ever will.
const LEGACY_CACHE_PREFIX = "flutter-";

// Every client-side (go_router) route resolves to this document.
const SHELL_DOCUMENT = "/index.html";

// Path prefixes this ORIGIN routes to backend services rather than to the PWA
// container (infra/helm/beekeepingit/charts/gateway/values.yaml — `routes` and
// `powersyncRoute`). They are not client-side routes, so a navigation to one
// must reach the server.
//
// This matters because the worker's scope is the whole origin, not just what
// nginx serves: the gateway peels `/v1/*` and `/sync-stream` off before nginx
// ever sees them, so "answer any navigation with index.html, exactly as the SPA
// fallback would" is true for nginx's paths and FALSE for these. Nothing in the
// app navigates to one today — every API call is `fetch`, which never reaches
// the navigation branch — but a downloaded export, a presigned-object redirect
// or a `.well-known` endpoint would, and would silently receive the app instead.
const SERVER_ROUTED_PREFIXES = ["/v1/", "/sync-stream"];

// The message `client/web/sw_register.js` posts. See the handler.
const BOOT_RESOURCES_MESSAGE = "bkit:boot-resources";

// Whether the manifest injection actually ran. Every build site in CI runs the
// generator (guarded by scripts/check-app-shell-precache-wired.sh), so the only
// output that keeps the empty defaults above is a bare, manual
// `flutter build web` or a `flutter run` dev session. This worker then stays
// completely inert: it caches nothing, handles no fetch, and — importantly —
// deletes nothing, so serving such a bundle behaves exactly as it did before
// this file existed instead of destroying a shell a real build left behind.
const isBuilt = PRECACHE.length > 0;

// Paths are matched after normalisation through `URL`, so a manifest entry
// containing a character that percent-encodes still equals the `url.pathname`
// the browser hands the fetch handler.
const toPaths = (entries) =>
  new Set(entries.map((entry) => new URL(entry.url, self.location.href).pathname));

const precachedPaths = toPaths(PRECACHE);
const runtimePaths = toPaths(RUNTIME);

// How many precache fetches run at once. Sequential would make an ~6.6 MB shell
// painfully slow on a field connection; unbounded would open a socket per file
// and compete with the very boot the user is waiting on.
const PRECACHE_CONCURRENCY = 6;

self.addEventListener("install", (event) => {
  event.waitUntil(install());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(activate());
});

// The page reporting which same-origin resources it actually loaded while
// booting (posted by client/web/sw_register.js).
//
// This exists because of a race the runtime tier cannot win on its own. On a
// FIRST visit the worker is registered at `load` and then spends seconds
// precaching, so by the time it activates and claims the page the engine has
// long since fetched its CanvasKit variant — through no worker at all, so
// nothing stored it. A user who visits once and then drives out of signal would
// find an app with no engine to paint with. The page can see what it loaded
// (`performance.getEntriesByType("resource")`), so it tells us. Verified: with
// the fetch handler alone, `client/e2e/tests/offline-boot.spec.ts` fails on
// exactly that.
//
// The message is UNTRUSTED input — anything running script on this origin can
// post one — so it is a hint, not an instruction: a reported URL is fetched
// only if it is same-origin AND already listed in this build's RUNTIME
// manifest. The worst a forged message can do is warm an entry this worker
// would have stored on first use anyway.
self.addEventListener("message", (event) => {
  if (!isBuilt) return;
  const data = event.data;
  if (data === null || typeof data !== "object") return;
  if (data.type !== BOOT_RESOURCES_MESSAGE || !Array.isArray(data.urls)) return;
  event.waitUntil(storeReportedResources(data.urls));
});

self.addEventListener("fetch", (event) => {
  if (!isBuilt) return;

  const request = event.request;
  // Plain GETs only. A POST/PUT is a mutation and a cache must never answer it.
  if (request.method !== "GET") return;

  // Range requests (media seeking) must reach the server: a stored 200 is not a
  // valid answer to a `Range` header, and returning one breaks the consumer.
  if (request.headers.has("range")) return;

  let url;
  try {
    url = new URL(request.url);
  } catch {
    return;
  }
  // Same-origin only. Anything else — the IdP included — is none of our
  // business and is left entirely to the browser.
  if (url.origin !== self.location.origin) return;

  // A navigation is the offline entry point: serve the cached shell document
  // for any CLIENT-SIDE route, as nginx's SPA fallback would.
  if (request.mode === "navigate") {
    if (SERVER_ROUTED_PREFIXES.some((prefix) => url.pathname.startsWith(prefix))) return;
    event.respondWith(shellDocument(request));
    return;
  }

  if (precachedPaths.has(url.pathname)) {
    event.respondWith(cacheFirst(request, url.pathname, false));
    return;
  }
  if (runtimePaths.has(url.pathname)) {
    event.respondWith(cacheFirst(request, url.pathname, true));
  }

  // Everything else falls through with no `respondWith` at all.
});

// Fills this build's cache, then takes over from the previous worker.
async function install() {
  if (isBuilt) await precache();
  await self.skipWaiting();
}

// Drops every other build's shell and starts controlling the open pages.
//
// The sweep is unconditional for a built worker, and that is a deliberate
// trade. Deferring it while a page from the previous build is still open would
// narrow the window in which that page can be handed a newer asset for a stable
// name — but nothing would ever reopen to finish the job, so every release
// would leave its shell behind and a long-lived installed PWA would accumulate
// ~7 MB per release until the origin's quota is hit. A quota failure breaks
// `install` outright, i.e. it costs the offline shell entirely, which is a far
// worse outcome than a window that already exists today at the HTTP layer (see
// the header comment) and that #678 closes properly.
async function activate() {
  // An UNGENERATED worker must destroy nothing. Its CACHE_NAME would be
  // `bkit-app-shell-unbuilt`, so an unguarded sweep would delete every real
  // build's shell while caching nothing in its place — reproducing #619 exactly.
  if (!isBuilt) return;

  const keys = await caches.keys();
  await Promise.all(
    keys
      .filter(
        (key) =>
          (key.startsWith(CACHE_PREFIX) && key !== CACHE_NAME) ||
          key.startsWith(LEGACY_CACHE_PREFIX),
      )
      .map((key) => caches.delete(key)),
  );
  // Control the page that just registered us, so the FIRST visit is already
  // covered rather than only the one after it.
  await self.clients.claim();
}

// Downloads and stores every `PRECACHE` entry. Throwing here fails `install`,
// which is correct: a half-populated shell would boot offline into a broken
// app, and a failed install leaves the PREVIOUS worker active and its shell
// intact rather than replacing a working one with a broken one. The browser
// does not retry a failed install on its own — `sw_register.js` calls
// `register()` on every load, so the next visit tries again.
async function precache() {
  const cache = await caches.open(CACHE_NAME);
  const queue = PRECACHE.slice();

  const drain = async () => {
    for (;;) {
      const entry = queue.shift();
      if (entry === undefined) return;
      // `cache: "no-cache"`, NOT `"reload"`. Both guarantee the stored copy is
      // current — the shell must never be built out of a response the browser
      // is merely holding — but `"reload"` re-downloads the bytes
      // unconditionally, which on a first visit would mean paying for the whole
      // ~6.6 MB shell a SECOND time, immediately after the page itself
      // downloaded most of it, on the mobile connection NFR-PER-1 and C-2 are
      // about. `"no-cache"` forces the conditional request and lets a 304 reuse
      // the body: same freshness guarantee, near-zero bytes. It does not depend
      // on nginx's own `Cache-Control` (#621) being right, which is the reason
      // to set it here at all.
      const request = new Request(entry.url, { cache: "no-cache" });
      const response = await fetch(request);
      assertRealAsset(entry.url, response);
      // Stored AS RECEIVED, headers included. That is load-bearing: the cached
      // `/index.html` still carries nginx's Cross-Origin-Opener-Policy and
      // Cross-Origin-Embedder-Policy, so a document served from this cache is
      // still cross-origin isolated and PowerSync's wasm/OPFS sync worker still
      // starts. Synthesising a `new Response(...)` here would silently drop
      // that, and the app would stop syncing with nothing else failing. It is
      // also why nginx.conf's bytes feed BUILD_REVISION: these headers are
      // frozen into the cache until the next update check.
      await cache.put(request, response);
    }
  };

  await Promise.all(Array.from({ length: Math.min(PRECACHE_CONCURRENCY, queue.length) }, drain));
}

// Stores the RUNTIME-tier resources a page reports having loaded. Silently
// ignores everything else — this is a warm-up, not a fetch API.
async function storeReportedResources(urls) {
  const cache = await caches.open(CACHE_NAME);
  const seen = new Set();
  for (const reported of urls) {
    if (typeof reported !== "string") continue;
    let url;
    try {
      url = new URL(reported, self.location.href);
    } catch {
      continue;
    }
    if (url.origin !== self.location.origin) continue;
    // The gate: only paths this build already committed to caching.
    if (!runtimePaths.has(url.pathname) || seen.has(url.pathname)) continue;
    seen.add(url.pathname);
    if (await matchCached(url.pathname)) continue;

    try {
      const response = await fetch(new Request(url.pathname, { cache: "no-cache" }));
      assertRealAsset(url.pathname, response);
      await cache.put(url.pathname, response);
    } catch {
      // Best effort: the fetch handler still stores it on the next use.
    }
  }
}

// The app shell for a navigation: cache first, network as the fallback.
async function shellDocument(request) {
  const cached = await matchCached(SHELL_DOCUMENT);
  if (cached) return cached;
  return fetch(request);
}

// A manifest entry: cache first, network as the fallback. Matched by pathname,
// so a `?v=`-style query string still hits the stored copy. `store` writes a
// successful network response back into this build's cache — used only for the
// runtime tier, never for anything outside the manifest.
async function cacheFirst(request, pathname, store) {
  const cached = await matchCached(pathname);
  if (cached) return cached;

  const response = await fetch(request);
  if (store) {
    try {
      assertRealAsset(pathname, response);
      const cache = await caches.open(CACHE_NAME);
      await cache.put(pathname, response.clone());
    } catch {
      // Serve it anyway; just don't store something suspect.
    }
  }
  return response;
}

// A cache lookup that can never take the app down. If this build's cache has
// been evicted while the registration survived, a rejection here would turn
// every navigation into a network error — including online ones — with no way
// back. Falling through to the network is always safe.
async function matchCached(pathname) {
  try {
    // `ignoreVary`: nginx does not send `Vary` on static files today, and
    // `Accept-Encoding` is a forbidden header name so both sides read null
    // either way — but a future `gzip_vary` must not turn every lookup into a
    // silent miss, i.e. a silently non-offline app.
    return await caches.match(pathname, { cacheName: CACHE_NAME, ignoreVary: true });
  } catch {
    return undefined;
  }
}

// Rejects anything that is not really the asset it was asked for.
//
// `response.ok` is not enough on this server: nginx's SPA fallback
// (`try_files $uri $uri/ /index.html`) answers ANY miss with 200 + the HTML
// document. So a moved asset, or a build served under an unexpected base href,
// would precache the shell document under every asset path — an install that
// SUCCEEDS and then boots offline into nothing. A redirect is refused for a
// different reason: a navigation's redirect mode is `manual`, and handing a
// `redirected` response to `respondWith` is a hard network error.
function assertRealAsset(pathname, response) {
  if (!response.ok) {
    throw new Error(`app-shell cache: HTTP ${response.status} for ${pathname}`);
  }
  if (response.redirected) {
    throw new Error(`app-shell cache: ${pathname} redirected`);
  }
  const isHtml = (response.headers.get("content-type") ?? "").includes("text/html");
  if (isHtml && !pathname.endsWith(".html")) {
    throw new Error(`app-shell cache: ${pathname} answered with the SPA fallback document`);
  }
}
