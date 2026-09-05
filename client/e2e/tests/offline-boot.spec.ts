import { test, expect, type Page } from "@playwright/test";
import { enableSemantics, gotoAppRoot } from "./helpers";

/**
 * The app shell boots with the network off (#619, FR-OF-1, FR-PL-1, NFR-PER-1,
 * D-10, NFR-TST-1).
 *
 * Until #619 the deployed `flutter_service_worker.js` was Flutter's
 * self-unregistering deprecation stub (flutter/flutter#156910): `install` →
 * `skipWaiting()`, `activate` → `self.registration.unregister()` plus a reload
 * of every client. So after every load the app had ZERO service-worker
 * registrations and ZERO caches and could not start without a connection — in
 * an app whose entire premise is a beekeeper standing in a field with no
 * signal. It went unnoticed for a release because the e2e suite always ran
 * online and the Lighthouse installability audit checks that a worker is
 * *registered*, not that it caches anything. This spec is the check that was
 * missing.
 *
 * It is the only spec that runs WITH service workers: `playwright.config.ts`
 * blocks them suite-wide (see the rationale there) and this file opts back in.
 *
 * WHY IT IS SHAPED LIKE THIS. An offline test is an absence assertion, and this
 * repo does not accept those on their own (`same-origin-boot.spec.ts`,
 * `cache-headers.spec.ts`). Three things could each make a naive version pass
 * while proving nothing:
 *
 *  1. The worker never installed → nothing is cached, but a "the page loaded"
 *     assertion could still be satisfied by the network. So the online half
 *     asserts the registration, the cache identity, and named cache entries
 *     FIRST.
 *  2. `context.setOffline(true)` did not actually take effect for this
 *     navigation → the shell came off the wire. So a negative control runs
 *     immediately before the reload: a same-origin path the worker deliberately
 *     does not handle must succeed online and REJECT offline.
 *  3. The document came back but Flutter never painted → a 200 is not a
 *     rendered app. So the offline half drives semantics and asserts a real,
 *     named control, plus `crossOriginIsolated` (which is what PowerSync's
 *     wasm/OPFS worker needs, and which is only true if the CACHED response
 *     still carries nginx's COOP/COEP — see the `cache.put` note in the
 *     worker).
 *
 * The release-invalidation half of the issue (a new build must not leave users
 * pinned to an old shell) is proved in two places: the mechanism, here, by
 * showing the revision the worker embeds for a file really is the sha-256 of
 * the bytes that file is served with — so any changed byte necessarily changes
 * the worker script the browser update-checks, and therefore the cache name;
 * and the behaviour, in `client/test/tool/build_app_shell_cache_test.dart`,
 * which flips a byte and asserts the revision moves.
 */

test.use({ serviceWorkers: "allow" });

// A same-origin path the worker deliberately does not handle: not a navigation,
// and not in the precache manifest, so it falls through to the network
// untouched. Online, nginx's SPA fallback answers it 200; offline, nothing can.
const PASSTHROUGH_PROBE = "/__offline-boot-probe-619__";

const APP_ORIGIN = process.env.E2E_BASE_URL ?? "https://app.beekeepingit.local:8443";

const CACHE_PREFIX = "bkit-app-shell-";

// Decoys seeded before the worker ever activates, so its cache sweep has
// something real to delete. Without them "exactly one shell cache exists" is
// true of a fresh browser profile whether the sweep runs or not — the whole
// eviction half of the issue would be asserted by a tautology.
const STALE_SHELL_CACHE = `${CACHE_PREFIX}stale-decoy`;
const LEGACY_FLUTTER_CACHE = "flutter-app-cache";

type ShellState = {
  registrations: string[];
  controller: string | null;
  allCacheNames: string[];
  cacheNames: string[];
  entries: string[];
  runtimeManifest: string[];
};

// Everything the online half needs to know about the worker, read from the page
// in one round trip.
async function readShellState(page: Page): Promise<ShellState> {
  return page.evaluate(async (prefix: string) => {
    const registrations = await navigator.serviceWorker.getRegistrations();
    const allCacheNames = await caches.keys();
    const cacheNames = allCacheNames.filter((name) => name.startsWith(prefix));
    const entries: string[] = [];
    for (const name of cacheNames) {
      const cache = await caches.open(name);
      for (const request of await cache.keys()) entries.push(new URL(request.url).pathname);
    }
    // The RUNTIME tier as the DEPLOYED worker declares it. Read from the served
    // script rather than hardcoded, so the spec follows a build that changes
    // which files are lazily cached.
    const source = await fetch("/service_worker.js", { cache: "no-store" }).then((response) =>
      response.text(),
    );
    const runtimeBlock = source.match(/const RUNTIME = \[([\s\S]*?)\];/)?.[1] ?? "";
    return {
      registrations: registrations.map(
        (registration) =>
          registration.active?.scriptURL ??
          registration.waiting?.scriptURL ??
          registration.installing?.scriptURL ??
          "",
      ),
      controller: navigator.serviceWorker.controller?.scriptURL ?? null,
      allCacheNames,
      cacheNames,
      entries,
      runtimeManifest: [...runtimeBlock.matchAll(/url: "([^"]+)"/g)].map((match) => match[1]),
    };
  }, CACHE_PREFIX);
}

// The sha-256 of what the ORIGIN serves at `path`, hex.
//
// Deliberately measured from a service-worker-free context: in the app's own
// page every manifest path is answered out of Cache Storage, so hashing there
// would compare the manifest against the cache it was used to fill — true, and
// not the claim. It has to run in a browser context all the same, because only
// the browser carries the `--host-resolver-rules` that make the dev hostnames
// resolve (playwright.config.ts); Playwright's Node-side `request` fixture
// cannot reach them.
async function servedDigest(page: Page, path: string): Promise<string> {
  return page.evaluate(async (target: string) => {
    const bytes = await fetch(target, { cache: "no-store" }).then((response) =>
      response.arrayBuffer(),
    );
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }, path);
}

// The waits below are individually generous because a cold k3d cluster is slow
// in ways that have nothing to do with this feature, and each one carries its
// own diagnosis. Their sum exceeds the suite default (playwright.config.ts), so
// state it here rather than letting a slow-but-passing run die on the suite
// timeout with no message.
test.setTimeout(420_000);

test("the shell is precached online, and the app renders from it with the network off", async ({
  page,
  context,
}) => {
  // Seed a previous build's shell and a Flutter-era cache BEFORE anything
  // registers, so `activate`'s sweep has something real to delete. Runs ahead
  // of every page script on every navigation.
  await context.addInitScript(
    ([stale, legacy]: string[]) => {
      void caches.open(stale);
      void caches.open(legacy);
    },
    [STALE_SHELL_CACHE, LEGACY_FLUTTER_CACHE],
  );

  // ── Online: the worker must install, take control, and precache ────────
  await gotoAppRoot(page);

  // Read the deployed worker FIRST. If the build never ran the manifest
  // generator the worker is inert — it never claims the page — and every wait
  // below would time out with a generic message instead of the one diagnosis
  // that explains it.
  const workerSource = await page.evaluate(() =>
    fetch("/service_worker.js", { cache: "no-store" }).then((response) => response.text()),
  );
  const buildRevision = workerSource.match(/const BUILD_REVISION = "([0-9a-f]+)"/)?.[1];
  expect(
    buildRevision,
    "the deployed worker still carries its placeholder manifest — the build " +
      "never ran `dart run tool/build_app_shell_cache.dart build/web`, so nothing " +
      "is precached and the app cannot start offline (#619)",
  ).toMatch(/^[0-9a-f]{16}$/);

  // `install` resolves only once the precache is fully written, and `activate`
  // (which calls `clients.claim()`) only runs after that — so a non-null
  // controller means the shell is already on disk. Registration itself is
  // deferred to `window.load`, hence the wait rather than an immediate read.
  await page.waitForFunction(() => navigator.serviceWorker.controller !== null, null, {
    timeout: 120_000,
  });

  await enableSemantics(page);
  const signIn = page.getByRole("button", { name: /sign in/i });
  await expect(signIn).toBeVisible({ timeout: 120_000 });

  // The engine variant is warmed by `sw_register.js` reporting what the page
  // loaded, which is an independent async fetch inside the worker — nothing the
  // steps above wait on. Poll: this is the entry the offline reload most
  // depends on, and reading it once would be a race, not an assertion.
  await expect
    .poll(
      async () => (await readShellState(page)).entries.filter((p) => p.startsWith("/canvaskit/")),
      {
        timeout: 60_000,
        message:
          "the CanvasKit variant this browser booted was never stored — an offline boot " +
          "has no engine to paint with. The worker cannot know at install time which of " +
          "the six shipped variants a browser wants, so sw_register.js reports what the " +
          "page actually loaded; this failing means that report never arrived, or the " +
          "engine moved out of the RUNTIME manifest.",
      },
    )
    .not.toEqual([]);

  const online = await readShellState(page);

  // Exactly one registration, and it is OURS. This is the #619 regression
  // itself: Flutter's stub claims the same `/` scope, and its `unregister()`
  // on activate would take our registration with it.
  expect(online.registrations).toHaveLength(1);
  expect(online.registrations[0]).toContain("/service_worker.js");
  expect(
    online.registrations.join(" "),
    "Flutter's self-unregistering deprecation stub must not be registered (#619)",
  ).not.toContain("flutter_service_worker.js");
  expect(online.controller).toContain("/service_worker.js");

  // Exactly one shell cache, AND the decoys are gone. The second half is what
  // makes this an assertion rather than a tautology: in a fresh context exactly
  // one cache exists whether or not `activate` sweeps, so deleting the sweep
  // would leave a length check green. The decoys were seeded before anything
  // registered, so their absence is the eviction of an old build's shell —
  // #619's fourth criterion, observed rather than argued.
  expect(online.cacheNames).toHaveLength(1);
  expect(
    online.allCacheNames,
    "a previous build's shell survived the new worker's activation, so a " +
      "released fix would sit behind a stale cache",
  ).not.toContain(STALE_SHELL_CACHE);
  expect(
    online.allCacheNames,
    "the caches Flutter's own worker left behind are never reclaimed, and they " +
      "compete for the very quota this shell needs",
  ).not.toContain(LEGACY_FLUTTER_CACHE);

  // Named entries, not a count: a threshold would keep passing while the thing
  // that actually has to be there went missing.
  expect(online.entries).toEqual(
    expect.arrayContaining([
      "/index.html", // the shell document every offline route resolves to
      "/main.dart.js", // the application itself
      "/flutter_bootstrap.js",
      "/flutter.js",
      "/sw_register.js",
      "/assets/fonts/Roboto/Roboto-Regular.ttf", // text has to render (#620)
      "/assets/AssetManifest.bin",
      "/sqlite3.wasm", // PowerSync's local store (EPIC-06)
      "/powersync_db.worker.js",
    ]),
  );
  // ── The release-invalidation mechanism (#619 AC 4) ─────────────────────
  // The cache above is named for BUILD_REVISION, which the build derives from a
  // per-file sha-256. Proving that the embedded revision for a file IS the
  // digest of the bytes the origin serves for it is what makes "a new release
  // invalidates the shell" a mechanism rather than a hope: change any byte and
  // the worker script the browser update-checks necessarily changes with it —
  // and the assertion above then shows what that produces.
  expect(online.cacheNames[0]).toBe(`${CACHE_PREFIX}${buildRevision}`);

  // A second context with service workers BLOCKED, so the digests below are of
  // what nginx put on the wire. In the app's own page every manifest path is
  // answered from Cache Storage, which would compare the manifest against the
  // cache it filled.
  const bare = await context.browser()!.newContext({
    baseURL: APP_ORIGIN,
    ignoreHTTPSErrors: true,
    serviceWorkers: "block",
  });
  try {
    const barePage = await bare.newPage();
    await barePage.goto("/", { waitUntil: "domcontentloaded" });

    for (const path of ["/index.html", "/main.dart.js"]) {
      const embedded = workerSource.match(
        new RegExp(`\\{ url: "${path}", revision: "([0-9a-f]+)" \\}`),
      )?.[1];
      expect(embedded, `${path} is missing from the deployed precache manifest`).toBeTruthy();
      expect(
        await servedDigest(barePage, path),
        `${path}'s manifest revision is not the digest of the bytes served for it, ` +
          `so a change to it would not necessarily change the worker or its cache name`,
      ).toMatch(new RegExp(`^${embedded}`));
    }
  } finally {
    await bare.close();
  }

  // ── The negative control ───────────────────────────────────────────────
  const probeOnline = await page.evaluate(
    (path: string) =>
      fetch(path)
        .then((response) => `HTTP ${response.status}`)
        .catch((error: Error) => `rejected: ${error.message}`),
    PASSTHROUGH_PROBE,
  );
  expect(probeOnline, "the probe path must be reachable while online").toBe("HTTP 200");

  await context.setOffline(true);

  const probeOffline = await page.evaluate(
    (path: string) =>
      fetch(path)
        .then((response) => `HTTP ${response.status}`)
        .catch(() => "rejected"),
    PASSTHROUGH_PROBE,
  );
  expect(
    probeOffline,
    "the browser is still reaching the network, so nothing below would prove " +
      "the app booted from cache",
  ).toBe("rejected");

  // The second half of the control, and the one that matters more. The probe
  // above is a PAGE fetch the worker never handles, so it only proves the
  // page's own network is off. Every fallback in the worker
  // (`shellDocument`, `cacheFirst`) is a fetch from the WORKER's context, and
  // if offline emulation did not reach that, an uncached asset would quietly
  // come off the wire and the offline half below would prove much less than it
  // claims. So: take a path the worker DOES handle but has not cached — a
  // RUNTIME entry for an engine variant this browser never booted — and require
  // the worker's own fallback to fail too.
  const uncachedManifestPath = online.runtimeManifest.find(
    (path) => !online.entries.includes(path),
  );
  expect(
    uncachedManifestPath,
    "the deployed manifest has no un-stored RUNTIME entry, so this control " +
      "cannot be run — pick a different worker-handled path",
  ).toBeTruthy();

  const workerProbeOffline = await page.evaluate(
    (path: string) =>
      fetch(path)
        .then((response) => `HTTP ${response.status}`)
        .catch(() => "rejected"),
    uncachedManifestPath as string,
  );
  expect(
    workerProbeOffline,
    "the SERVICE WORKER's own fetch still reached the network, so a cache miss " +
      "below could be silently served online and prove nothing",
  ).toBe("rejected");

  // ── Offline: a full reload must render the app, not an error page ──────
  //
  // A DEEP LINK, not `/`. Every go_router route resolves to the same document,
  // and offline that answer can only come from the worker's navigation branch —
  // nginx's `try_files` fallback, which handles this online, is unreachable. So
  // this covers both "the app opens offline" and "an offline deep link still
  // opens the app", which `/` alone does not.
  await page.goto("/apiaries", { waitUntil: "domcontentloaded" });

  await page.waitForSelector("flt-glass-pane, flutter-view", { timeout: 120_000 });
  await enableSemantics(page);
  await expect(
    page.getByRole("button", { name: /sign in/i }),
    "the shell document came back, but Flutter never rendered its login screen",
  ).toBeVisible({ timeout: 120_000 });

  const offline = await page.evaluate(() => ({
    controller: navigator.serviceWorker.controller?.scriptURL ?? null,
    crossOriginIsolated: self.crossOriginIsolated,
  }));
  expect(offline.controller, "the offline load was not served by our worker").toContain(
    "/service_worker.js",
  );
  // The cached document must still carry nginx's COOP/COEP. Without them the
  // origin is not cross-origin isolated, SharedArrayBuffer is unavailable, and
  // PowerSync's wasm/OPFS sync worker cannot start — so the app would come back
  // offline and then be unable to sync when the signal returns.
  expect(
    offline.crossOriginIsolated,
    "the cached shell document lost its COOP/COEP headers — PowerSync's sync " +
      "worker cannot start",
  ).toBe(true);

  await context.setOffline(false);
});
