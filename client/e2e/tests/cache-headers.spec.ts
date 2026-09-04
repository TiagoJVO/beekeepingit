import { test, expect, type Page } from "@playwright/test";

/**
 * Cache headers for the client bundle (#621, FR-PL-1, D-10).
 *
 * The PWA container (client/nginx.conf) sends an explicit
 * `Cache-Control: no-cache` for everything it serves. Before #621 neither `/`
 * nor `/main.dart.js` carried the header at all, so every browser fell back to
 * HEURISTIC caching — an implementation-defined freshness guess derived from
 * Last-Modified, which can hold a stale bundle for an unbounded window after a
 * release. `no-cache` does NOT mean "don't store": it means store, but
 * revalidate before reuse, so nginx's ETag/Last-Modified turn repeat loads into
 * cheap 304s while a new release is picked up on the very next load.
 *
 * Nothing here may be `immutable`, and asserting `no-cache` on main.dart.js is
 * what pins that: `flutter build web` emits ZERO content-hashed filenames
 * (main.dart.js, flutter_bootstrap.js, canvaskit/*, sqlite3.wasm,
 * powersync_db.worker.js and the tree-shaken MaterialIcons-Regular.otf are all
 * STABLE names whose bytes change per release), so a long max-age + immutable
 * would pin users to a stale build with no reload escape.
 *
 * HTTP caching is no longer the only cache layer: since #619 the app registers
 * an app-shell service worker that answers bundle paths out of the Cache API.
 * That worker must NOT be in the picture here. `cache: "no-store"` below is an
 * HTTP-cache directive and does not bypass a service worker, so a controlled
 * page would answer most of these probes from Cache Storage — and they would
 * still PASS, because a stored response keeps the headers it was stored with.
 * That is worse than failing: this spec's entire claim is that it measured what
 * nginx put on the wire, and the add_header inheritance canary at the bottom
 * would silently stop guarding nginx.conf. `playwright.config.ts` therefore
 * blocks service workers suite-wide, and only offline-boot.spec.ts opts in.
 *
 * WHY every header read goes through the browser: Playwright's Node-side
 * `request` fixture issues plain Node HTTP, which does NOT get the browser
 * launch's `--host-resolver-rules` (playwright.config.ts's hostMap) that is the
 * whole reason the dev hostnames resolve without editing the runner's
 * /etc/hosts — it simply cannot resolve app.beekeepingit.local. So the probes
 * are same-origin in-page fetches with RELATIVE paths (the same technique as
 * slice.spec.ts's serverApiary). `cache: "no-store"` on each fetch is required
 * so the browser's own HTTP cache cannot answer from a copy it already holds
 * (from the page load below) and hand us headers that never came off the wire
 * on this request.
 */

// What a path's `Content-Type` must look like. `not-contains` is for responses
// whose exact type we deliberately don't pin — see AssetManifest.bin below.
type ContentTypeExpectation =
  { kind: "contains"; value: string } | { kind: "not-contains"; value: string };

type BundleEntry = { path: string; contentType: ContentTypeExpectation };

const contains = (value: string): ContentTypeExpectation => ({ kind: "contains", value });
const notContains = (value: string): ContentTypeExpectation => ({ kind: "not-contains", value });

// One representative path per asset class the nginx container serves, each
// carrying what its Content-Type must look like.
//
// WHY the content-type matters: a bare `200` proves nothing here. nginx's SPA
// fallback (`location / { try_files $uri $uri/ /index.html; }`) answers ANY
// missing path with HTTP 200 + index.html, so a status check alone cannot tell
// "this asset exists and carries the header" from "this asset is gone and I
// just re-measured the document's headers ten times". A Flutter upgrade that
// renames or relocates an output (a --wasm build emitting main.dart.mjs instead
// of main.dart.js, canvaskit moving, AssetManifest.bin changing form) would
// otherwise leave this spec green while it silently covers nothing. Asserting
// the content-type per asset class costs no extra request and makes that
// collapse-to-the-fallback-document failure loud.
//
// All of these are stable, non-content-hashed names — which is exactly why all
// of them must revalidate.
const BUNDLE_PATHS: BundleEntry[] = [
  // The document, deliberately as three shapes: `/`, the explicit file, and a
  // client-side (go_router) route that exists ONLY via the try_files fallback.
  // All three are legitimately the same HTML document and must carry the same
  // policy — for these, `text/html` is the expected answer, not the failure.
  { path: "/", contentType: contains("text/html") },
  { path: "/index.html", contentType: contains("text/html") },
  { path: "/home", contentType: contains("text/html") },
  // Flutter's entrypoint, loader scripts and the CanvasKit renderer. nginx maps
  // `.js` to application/javascript (text/javascript on newer mime.types), so
  // match the substring both forms share.
  { path: "/main.dart.js", contentType: contains("javascript") },
  { path: "/flutter_bootstrap.js", contentType: contains("javascript") },
  { path: "/flutter.js", contentType: contains("javascript") },
  { path: "/canvaskit/canvaskit.js", contentType: contains("javascript") },
  // The app-shell service worker (#619). It belongs in this list by the rule
  // above — another stable, non-content-hashed name — and it is the one file
  // where staleness is total: the browser's update check is what swaps the
  // whole cached shell, so a worker served from a stale copy pins users to an
  // old build with no reload escape. It also needs NO location block of its own
  // in nginx.conf; `no-cache` is already the server-wide default, and a
  // location-level add_header would cancel COOP/COEP (see the canary below).
  { path: "/service_worker.js", contentType: contains("javascript") },
  // Build + PWA metadata.
  { path: "/version.json", contentType: contains("json") },
  { path: "/manifest.json", contentType: contains("json") },
  // A bundled asset. Asserted only as "did NOT collapse to the fallback
  // document": nginx types `.bin` as application/octet-stream today, but
  // over-pinning that exact string would break this spec on an unrelated
  // mime.types bump without any regression in what it guards.
  { path: "/assets/AssetManifest.bin", contentType: notContains("text/html") },
];

// `/` and the app's biggest script: enough to prove the server-level headers
// reach BOTH the SPA-fallback document and a plain static file.
const SECURITY_HEADER_PATHS = ["/", "/main.dart.js"];

type Probe = {
  path: string;
  status: number;
  cacheControl: string | null;
  contentType: string | null;
  contentTypeOptions: string | null;
  openerPolicy: string | null;
  embedderPolicy: string | null;
};

// This spec needs ONE thing from the navigation: a same-origin document to
// fetch from. It does NOT need Flutter to boot — so it deliberately does not
// use helpers.ts's gotoAppRoot, which waits up to 120s for the glass pane. With
// that helper, any unrelated app-boot regression (PowerSync's worker, CanvasKit,
// cross-origin isolation) would report as a *cache-headers* failure and send
// the reader to the wrong file.
//
// The 5xx tolerance is kept, and is not optional: on a freshly-booted k3d
// cluster the gateway really does answer Traefik's own 502 page for a short
// window, and we must not measure THAT origin's headers.
async function gotoSameOriginDocument(page: Page) {
  const deadline = Date.now() + 60_000;
  let lastStatus: number | null = null;
  for (;;) {
    const resp = await page.goto("/", { waitUntil: "domcontentloaded" }).catch(() => null);
    lastStatus = resp?.status() ?? lastStatus;
    if (resp != null && resp.status() < 500) return;
    if (Date.now() > deadline) {
      throw new Error(
        `the app origin never answered below 5xx (last HTTP status ${
          lastStatus ?? "unknown"
        }) — the gateway/PWA route is not ready, so no header here would be the PWA container's`,
      );
    }
    await page.waitForTimeout(3_000);
  }
}

// Deliberately ONE test and no login: it costs a single page load plus ten
// same-origin fetches, which keeps it near-free inside the helm-e2e job's
// budget (the other specs each spend at least one full OIDC round trip).
test("the served bundle revalidates (Cache-Control: no-cache) and keeps its security headers", async ({
  page,
}) => {
  await gotoSameOriginDocument(page);

  const probes: Probe[] = await page.evaluate(
    async (paths: string[]) => {
      const results: {
        path: string;
        status: number;
        cacheControl: string | null;
        contentType: string | null;
        contentTypeOptions: string | null;
        openerPolicy: string | null;
        embedderPolicy: string | null;
      }[] = [];
      for (const path of paths) {
        const res = await fetch(path, { cache: "no-store" });
        results.push({
          path,
          status: res.status,
          cacheControl: res.headers.get("cache-control"),
          contentType: res.headers.get("content-type"),
          contentTypeOptions: res.headers.get("x-content-type-options"),
          openerPolicy: res.headers.get("cross-origin-opener-policy"),
          embedderPolicy: res.headers.get("cross-origin-embedder-policy"),
        });
      }
      return results;
    },
    BUNDLE_PATHS.map((entry) => entry.path),
  );

  for (const entry of BUNDLE_PATHS) {
    const probe = probes.find((p) => p.path === entry.path);
    if (!probe) throw new Error(`no probe was recorded for ${entry.path}`);

    expect(
      probe.status,
      `${entry.path} must be served by the PWA container (got HTTP ${probe.status})`,
    ).toBe(200);

    // The status above is necessary but NOT sufficient (see BUNDLE_PATHS): the
    // content-type is what proves the path still resolves to the asset it names
    // rather than to the SPA fallback's index.html.
    const contentType = (probe.contentType ?? "").toLowerCase();
    const seen = probe.contentType ?? "no Content-Type at all";
    if (entry.contentType.kind === "contains") {
      expect(
        contentType,
        `${entry.path} must be served as "${entry.contentType.value}" (got ${seen}) — ` +
          `either the bundle no longer emits this path (try_files then answers 200 with ` +
          `index.html, making the Cache-Control assertion above vacuous) or its type changed`,
      ).toContain(entry.contentType.value);
    } else {
      expect(
        contentType,
        `${entry.path} must NOT be served as "${entry.contentType.value}" (got ${seen}) — ` +
          `that is nginx's try_files fallback answering with index.html, i.e. the bundle no ` +
          `longer emits this path and the Cache-Control assertion above covers nothing`,
      ).not.toContain(entry.contentType.value);
    }

    // `toContain`, not equality: the point is that the response is never reused
    // without revalidation. A future policy may legitimately add a companion
    // directive (e.g. `no-cache, no-store` on a specific path), but dropping
    // `no-cache` — or replacing it with `max-age=…, immutable` on these
    // non-content-hashed names — must fail here.
    expect(
      probe.cacheControl ?? "",
      `${entry.path} must carry Cache-Control: no-cache (got ${
        probe.cacheControl ?? "no header at all"
      })`,
    ).toContain("no-cache");
  }

  // ── Regression guard for nginx's add_header inheritance trap (#89) ─────
  // In nginx, `add_header` directives are inherited from the enclosing level
  // ONLY IF the current level defines none of its own: a single `add_header`
  // inside a `location {}` CANCELS every server-level `add_header`. Putting the
  // Cache-Control above inside `location / {}` would therefore have silently
  // dropped COOP/COEP, nosniff, Referrer-Policy and the Report-Only CSP from
  // every response served through that location, with no other test noticing.
  //
  // COOP/COEP are named explicitly because they are what breaks FIRST if that
  // trap is ever tripped: losing them loses cross-origin isolation, which
  // disables SharedArrayBuffer and therefore PowerSync's wasm/OPFS sync worker
  // — the app stops syncing. Asserting them (rather than leaning on nosniff as
  // a proxy) makes this canary self-explanatory. No extra requests: the values
  // came back on the same probes.
  for (const path of SECURITY_HEADER_PATHS) {
    const probe = probes.find((p) => p.path === path);
    if (!probe) throw new Error(`no probe was recorded for ${path}`);

    const trap =
      `a location-level add_header cancels inheritance of ALL server-level ` +
      `add_header directives (#89)`;
    expect(probe.contentTypeOptions, `${path} lost X-Content-Type-Options: nosniff — ${trap}`).toBe(
      "nosniff",
    );
    expect(
      probe.openerPolicy,
      `${path} lost Cross-Origin-Opener-Policy: same-origin — ${trap}. Without it the ` +
        `origin is not cross-origin isolated, SharedArrayBuffer is unavailable, and ` +
        `PowerSync's wasm/OPFS sync worker cannot start`,
    ).toBe("same-origin");
    expect(
      probe.embedderPolicy,
      `${path} lost Cross-Origin-Embedder-Policy: require-corp — ${trap}. Without it the ` +
        `origin is not cross-origin isolated, SharedArrayBuffer is unavailable, and ` +
        `PowerSync's wasm/OPFS sync worker cannot start`,
    ).toBe("require-corp");
  }
});
