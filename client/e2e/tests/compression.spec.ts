import { test, expect, type Page } from "@playwright/test";
import {
  contains,
  expectContentType,
  gotoSameOriginDocument,
  notContains,
  type ContentTypeExpectation,
} from "./helpers";

/**
 * The bundle is served compressed (#670, #688, NFR-PER-1, FR-OF-1, C-2, D-10).
 *
 * Until #670 nothing in the serving path compressed anything: `client/nginx.conf`
 * never enabled `gzip`, the `nginx:1.31-alpine` base ships it commented out in
 * its own config, and the Traefik in front of it has no compress middleware. So
 * a cold load pulled `main.dart.js` (4.4 MB) and the CanvasKit `.wasm` (5.8 MB)
 * whole, over the weak mobile connection this app is built for (FR-OF-1, C-2) —
 * and paid it again after every release invalidated the service worker's shell.
 *
 * WHY THIS RUNS IN A BROWSER AND NOT IN NODE. Only the browser carries the
 * `--host-resolver-rules` that make the dev hostnames resolve
 * (playwright.config.ts), so Playwright's own `request` fixture cannot reach the
 * deployment at all. The requests are therefore driven from inside the page —
 * but the ASSERTED headers are read off `page.on("response")`, i.e. from the
 * protocol-level response, not from what the renderer chooses to expose to
 * `fetch()`. `Content-Encoding` is exactly the header where those two can
 * differ between engines, and this spec has to measure the wire.
 *
 * WHY THERE IS ALSO A SIZE ASSERTION. A header on its own only says nginx
 * claimed to compress. `PerformanceResourceTiming` gives the real
 * `encodedBodySize` (bytes off the wire) against `decodedBodySize` (bytes the
 * app sees), same-origin and needing no Timing-Allow-Origin — so the saving is
 * measured, not inferred. It also has to be measured that way rather than from
 * `Content-Length`: on-the-fly gzip makes these responses chunked, so there is
 * no `Content-Length` to read. The numbers are printed, because #670's third
 * acceptance criterion — and #688's — is a real before/after measurement, and a
 * CI run of this spec is where the "after" half legitimately comes from.
 *
 * WHAT #688 ADDED. Enabling gzip only compresses what nginx has a MIME type
 * for, and the `nginx:1.31-alpine` stock `mime.types` has no `.ttf`/`.otf`
 * entry while `assets/NOTICES` has no extension at all — so ~1.9 MB of the
 * bundle kept falling through to the `application/octet-stream` `default_type`,
 * which `gzip_types` deliberately does not list. #688 typed them (an HTTP-level
 * `types` block plus one exact-match `location`, see `client/nginx.conf`) and
 * this spec is where that is proved on the wire: the font probes below are
 * positive, and the CONTENT-TYPE assertions on `/main.dart.js`,
 * `/canvaskit/chromium/canvaskit.wasm` and `/icons/Icon-512.png` are what
 * catches the way that fix goes wrong — a `types {}` in the wrong context
 * REPLACES the inherited map instead of extending it, collapsing every one of
 * those to `application/octet-stream` with `nginx -t` still green.
 *
 * WHY EVERY PROBE PINS A CONTENT-TYPE. A `200` proves nothing on this server:
 * nginx's SPA fallback (`try_files $uri $uri/ /index.html`) answers ANY miss
 * with 200 + `index.html` — a `text/html` document which IS compressed. So a
 * renamed, relocated or never-emitted asset would satisfy every gzip assertion
 * below while covering nothing at all. The content-type costs no extra request
 * and makes that collapse loud. For the `.wasm` probe it carries a second
 * claim: `application/wasm` has to actually be in the base image's
 * `mime.types`, or `gzip_types` could never match the largest file the app
 * downloads.
 *
 * WHY THERE ARE TWO NEGATIVE CONTROLS. "Already-compressed types are excluded"
 * is half of #670's acceptance criteria, and it is the half that a too-broad
 * `gzip_types` would break while every positive assertion here stayed green.
 * There is no negative directive in nginx to assert against — the allow-list IS
 * the exclusion mechanism — so the controls are the two ways it can go wrong:
 * naming an already-compressed type (`/icons/Icon-512.png`), and naming
 * nginx's `application/octet-stream` default_type, which would sweep in every
 * unrecognised file at once. The second control was `Roboto-Regular.ttf` until
 * #688 gave `.ttf` a real type; `/assets/shaders/ink_sparkle.frag` inherited
 * the role, because `.frag` is now the bundle's largest extension the stock
 * `mime.types` still does not recognise. It was NOT dropped when the font probe
 * flipped: a compression spec whose only negative control is one already-
 * compressed format cannot tell "octet-stream is excluded" from "octet-stream
 * is listed and everything is being compressed". Both controls are far above
 * `gzip_min_length`, so a missing `Content-Encoding` on them means the TYPE was
 * excluded rather than the file being too small to bother with. The bundle
 * emits no `.woff2` at all (Flutter bundles `.ttf`/`.otf`), so there is no path
 * to probe for that one; `font/woff2` is simply never named.
 *
 * Service workers are blocked suite-wide (playwright.config.ts) and this spec
 * does NOT opt back in — a response replayed out of Cache Storage keeps the
 * headers it was stored with, which would let every assertion below pass
 * without nginx being in the picture at all.
 */

type Probe = {
  path: string;
  contentType: ContentTypeExpectation;
  /** Whether this response must arrive gzip-encoded. */
  compressed: boolean;
  /** At most this fraction of the decoded size may come off the wire. */
  maxWireRatio?: number;
};

// One probe per asset class #670 and #688 name, each the load-bearing
// representative of its class rather than whatever happened to be in the bundle.
//
// `text/css` and `image/svg+xml` are in nginx's `gzip_types` but have no probe:
// a CanvasKit `flutter build web` emits neither today, so the config covers
// them for the day it does and there is nothing honest to assert now.
const PROBES: Probe[] = [
  // The document. `text/html` is nginx's one always-compressed type — it is
  // not, and must not be, listed in `gzip_types` — so this exercises a
  // different code path from everything below it.
  { path: "/index.html", contentType: contains("text/html"), compressed: true },
  // The whole Dart application: the single biggest thing #670 is about, and the
  // one probe carrying a ratio floor (see maxWireRatio below).
  {
    path: "/main.dart.js",
    contentType: contains("javascript"),
    compressed: true,
    // Measured at 32.8% of the decoded size (4,441,974 -> 1,458,316 B) at the
    // configured `gzip_comp_level 2`. The floor is 0.5 rather than something
    // near the measurement: nginx accepts levels 1-9 and even level 1 lands at
    // 34.0%, so no legal level can fail this. What it catches is a change in
    // KIND — a `gzip_types` entry that stops matching and leaves this response
    // being served identity while some hop still labels it, or a proxy that
    // decoded and re-framed the body. Tightening it toward the real ratio would
    // buy nothing and break on the next bundle that compresses differently.
    maxWireRatio: 0.5,
  },
  // The engine: at 5.8 MB the largest single file the app ever downloads, and
  // the variant Chromium boots (see the RUNTIME tier in
  // client/web/service_worker.js).
  {
    path: "/canvaskit/chromium/canvaskit.wasm",
    contentType: contains("application/wasm"),
    compressed: true,
  },
  // The loader, and the worker whose bytes drive shell invalidation (#619) —
  // the one file every client re-downloads on every update check.
  { path: "/flutter.js", contentType: contains("javascript"), compressed: true },
  { path: "/service_worker.js", contentType: contains("javascript"), compressed: true },
  // application/json. Small (856 B) and deliberately so: it sits just above
  // nginx's `gzip_min_length` of 256, so it doubles as the guard on that floor
  // not drifting back up to the kilobyte a stock config uses.
  { path: "/manifest.json", contentType: contains("json"), compressed: true },
  // The two font faces #688 typed, one per mapping. Roboto is the biggest
  // (171,676 B -> 96,391 B at level 2, 43.9%) and the one CanvasKit fetches on
  // EVERY cold boot as its hardcoded default family (#620); MaterialIcons is
  // the `.otf`, which is a separate `types` entry and would be missed by a fix
  // that only mapped `.ttf`. Both are PRECACHE-tier, so every client pays them
  // on every release. This probe was the spec's second negative control until
  // #688 — the comment below the list says what replaced it.
  {
    path: "/assets/fonts/Roboto/Roboto-Regular.ttf",
    contentType: contains("font/ttf"),
    compressed: true,
  },
  {
    path: "/assets/fonts/MaterialIcons-Regular.otf",
    contentType: contains("font/otf"),
    compressed: true,
  },
  // The licences text: 1,450,846 B and 89.2% compressible, the single largest
  // compressible file the bundle serves. It has no extension, so no `types`
  // entry can reach it — `client/nginx.conf` types it with an exact-match
  // `location`, and `text/plain` here is what proves that location is still
  // matching rather than the file quietly falling back to octet-stream again.
  // Runtime-tier in the service worker (fetched when the licences page opens),
  // not precache.
  {
    path: "/assets/NOTICES",
    contentType: contains("text/plain"),
    compressed: true,
    // Measured at 10.8% of decoded at level 2. Same reasoning as main.dart.js:
    // the floor is loose enough that no legal gzip level can fail it (level 1
    // lands at 11.6%) and exists to catch a change in KIND, not a drift in
    // ratio.
    maxWireRatio: 0.5,
  },
  // Negative control 1: an already-compressed format. Re-compressing it buys
  // ~4.9% for a full pass over 24 KB.
  { path: "/icons/Icon-512.png", contentType: contains("image/png"), compressed: false },
  // Negative control 2: a file nginx's mime.types STILL has no entry for, so it
  // is served as the `application/octet-stream` default_type — the role the
  // `.ttf` probe above played until #688 typed it. `.frag` is the largest such
  // extension left in the bundle (8,890 B). The `canvaskit/*.symbols` tables
  // used to be the bigger ones, but #701 stopped shipping them into the image
  // entirely — see the absence test below. It is NOT pinned to the
  // octet-stream string — only to "did
  // not collapse to the SPA fallback" — so that mapping `.frag` one day is a
  // one-line change here rather than a puzzle.
  //
  // What it guards: `application/octet-stream` entering `gzip_types`, which
  // would sweep in every binary the bundle serves, the PNGs included. That
  // failure is invisible to every positive probe above.
  {
    path: "/assets/shaders/ink_sparkle.frag",
    contentType: notContains("text/html"),
    compressed: false,
  },
];

// Every probe is requested with this query string appended.
//
// The navigation below boots the real app, which fetches `/main.dart.js`, the
// engine and the worker for itself — concurrently with, and indistinguishably
// from, this spec's own requests for the same paths. Without a discriminator
// both the `page.on("response")` map and `performance.getEntriesByName` could
// hand back the PAGE's load instead of the probe's, and the spec would be
// reporting a measurement it did not make. nginx ignores the query for a static
// file (`try_files` matches on `$uri`), so the bytes and headers are the same
// response — it just becomes addressable.
const PROBE_QUERY = "?compression-probe=670";

const probeUrl = (path: string) => `${path}${PROBE_QUERY}`;

const PROBE_URLS = PROBES.map((probe) => probeUrl(probe.path));

// What the page measured about one fetch.
type Timing = { path: string; status: number; encodedBodySize: number; decodedBodySize: number };

// Response headers as they came off the protocol, keyed by the probe's path.
type WireHeaders = Map<string, Record<string, string>>;

// Subscribes to the protocol-level responses for the probes before anything is
// requested. Returns a closure that settles the (async) header reads.
function captureWireHeaders(
  page: Page,
  into: WireHeaders,
  failures: Map<string, string>,
): () => Promise<void> {
  const pending: Promise<unknown>[] = [];
  page.on("response", (response) => {
    let url: URL;
    try {
      url = new URL(response.url());
    } catch {
      return;
    }
    if (`${url.pathname}${url.search}` !== probeUrl(url.pathname)) return;
    pending.push(
      response
        .allHeaders()
        .then((headers) => into.set(url.pathname, headers))
        // Recorded rather than swallowed: an unreadable header set and a
        // request that never left the browser are different diagnoses, and
        // reporting the second for the first sends the reader to the gateway.
        .catch((error: unknown) => failures.set(url.pathname, String(error))),
    );
  });
  return async () => {
    await Promise.all(pending);
  };
}

// Fetches every probe from inside the page and reports what the browser
// measured. `cache: "no-store"` keeps the browser's own HTTP cache from
// answering out of a copy the page load already put there, whose headers never
// came off the wire on this request.
async function fetchAndMeasure(page: Page, targets: string[]): Promise<Timing[]> {
  return page.evaluate(async (urls) => {
    // The buffer is shared with the page's own boot loads and holds 250 entries
    // by default. The probe URLs are unique (see PROBE_QUERY) so identity is
    // never in doubt, but a full buffer would drop them entirely and the
    // measurement would silently become -1.
    performance.clearResourceTimings();
    const timings = [];
    for (const url of urls) {
      const response = await fetch(url, { cache: "no-store" });
      // Drain the body: `encodedBodySize` is only final once the response has
      // been fully received.
      await response.arrayBuffer();
      const absolute = new URL(url, location.href);
      const entry = performance.getEntriesByName(absolute.href).at(-1) as
        PerformanceResourceTiming | undefined;
      timings.push({
        path: absolute.pathname,
        status: response.status,
        encodedBodySize: entry?.encodedBodySize ?? -1,
        decodedBodySize: entry?.decodedBodySize ?? -1,
      });
    }
    return timings;
  }, targets);
}

const kib = (bytes: number) => `${(bytes / 1024).toFixed(1)} KiB`;

// No `test.setTimeout` here on purpose: the suite default (240s,
// playwright.config.ts) is the right budget, and this spec is heavy enough that
// LOWERING it would be the mistake. It deliberately pulls the 5.8 MB engine and
// the 4.4 MB application through the gateway a second time — the page load
// already fetched them, and `no-store` is what makes the measurement honest —
// which with #688's three added probes is ~4.2 MB compressed on top of the boot.

test("the bundle is served gzip-encoded, and already-compressed types are not", async ({
  page,
}) => {
  const wire: WireHeaders = new Map();
  const headerFailures = new Map<string, string>();
  const settleHeaders = captureWireHeaders(page, wire, headerFailures);

  await gotoSameOriginDocument(page);
  const timings = await fetchAndMeasure(page, PROBE_URLS);
  await settleHeaders();

  const timingFor = (path: string) => {
    const timing = timings.find((candidate) => candidate.path === path);
    if (!timing) throw new Error(`no timing was recorded for ${path}`);
    return timing;
  };
  const headersFor = (path: string) => {
    const headers = wire.get(path);
    if (!headers) {
      const failure = headerFailures.get(path);
      throw new Error(
        failure !== undefined
          ? `the protocol-level headers for ${path} could not be read (${failure}) — a ` +
              `Playwright problem, not a server one; nothing below measured anything`
          : `no protocol-level response was observed for ${path} — the request never left ` +
              `the browser, so nothing below measured the server`,
      );
    }
    return headers;
  };

  // Real numbers first, so a CI log carries the measurement #670 and #688 ask
  // for, even on a run where everything passes.
  const report = PROBES.map(({ path }) => {
    const { encodedBodySize, decodedBodySize } = timingFor(path);
    const encoding = headersFor(path)["content-encoding"] ?? "identity";
    const saved =
      decodedBodySize > 0
        ? `${(100 - (encodedBodySize / decodedBodySize) * 100).toFixed(1)}%`
        : "—";
    return (
      `  ${path.padEnd(40)} ${encoding.padEnd(9)} wire ${kib(encodedBodySize).padStart(11)}` +
      `  decoded ${kib(decodedBodySize).padStart(11)}  saved ${saved}`
    );
  }).join("\n");
  console.log(`transfer sizes as served (#670, #688):\n${report}`);

  for (const probe of PROBES) {
    const { path } = probe;
    const timing = timingFor(path);
    const headers = headersFor(path);

    expect(timing.status, `${path} must be served by the PWA container`).toBe(200);
    expectContentType(path, probe.contentType, headers["content-type"] ?? null);

    if (!probe.compressed) {
      expect(
        timing.decodedBodySize,
        `${path} is under gzip_min_length, so the absence of a Content-Encoding below ` +
          `would prove nothing about the type exclusion this probe exists for`,
      ).toBeGreaterThan(1024);
      expect(
        headers["content-encoding"],
        `${path} was compressed. Either gzip_types has grown to cover an already-compressed ` +
          `format, or it picked up nginx's application/octet-stream default_type and now ` +
          `sweeps in everything, the .png icons included (#670, #688)`,
      ).toBeUndefined();
      continue;
    }

    expect(
      headers["content-encoding"],
      `${path} must be served gzip-encoded. It is not, which means nginx's gzip is off, ` +
        `this response's Content-Type is missing from gzip_types, or it fell under ` +
        `gzip_min_length (#670)`,
    ).toBe("gzip");

    // A shared cache that ignored Accept-Encoding would hand a gzip body to a
    // client that never asked for one. nginx sets this via `gzip_vary on`.
    expect(
      (headers["vary"] ?? "").toLowerCase(),
      `${path} was compressed without Vary: Accept-Encoding — gzip_vary is off (#670)`,
    ).toContain("accept-encoding");

    // The header claimed compression; this is the proof it happened.
    expect(
      timing.encodedBodySize,
      `${path} claimed Content-Encoding: gzip but ${kib(timing.encodedBodySize)} came off ` +
        `the wire for ${kib(timing.decodedBodySize)} of content — nothing was actually saved`,
    ).toBeLessThan(timing.decodedBodySize);

    if (probe.maxWireRatio !== undefined) {
      expect(
        timing.encodedBodySize / timing.decodedBodySize,
        `${path} compressed to ${kib(timing.encodedBodySize)} of ${kib(
          timing.decodedBodySize,
        )} — the header is present but the body is barely smaller, which is what a hop that ` +
          `decoded and re-framed the response looks like`,
      ).toBeLessThan(probe.maxWireRatio);
    }
  }

  // Compression must not have cost the cross-origin isolation the app syncs
  // with. The `gzip*` directives are not `add_header`, so they cannot trip
  // nginx's inheritance trap (#89) the way a location-level header would — but
  // they edit the same server block, and that failure is silent: `nginx -t`
  // green, pod Ready, PowerSync's wasm/OPFS worker simply never starting.
  // cache-headers.spec.ts owns the full canary; one probe here keeps this
  // change from depending on a different file to notice.
  const document = headersFor("/index.html");
  expect(
    document["cross-origin-opener-policy"],
    "compressing the bundle dropped COOP from the document — the origin is no longer " +
      "cross-origin isolated and PowerSync's sync worker cannot start (#89)",
  ).toBe("same-origin");
  expect(
    document["cross-origin-embedder-policy"],
    "compressing the bundle dropped COEP from the document — the origin is no longer " +
      "cross-origin isolated and PowerSync's sync worker cannot start (#89)",
  ).toBe("require-corp");
});

/**
 * The CanvasKit symbolication tables are not in the image at all (#701).
 *
 * A release `flutter build web` emits ~8.2 MB of `canvaskit/*.js.symbols` into
 * `build/web`, and `COPY build/web` shipped and publicly served every byte of
 * something no browser ever requests. `client/.dockerignore` now excludes them.
 *
 * Asserting their ABSENCE takes care, because nginx's SPA fallback
 * (`try_files $uri $uri/ /index.html`) answers a missing path with `200` and the
 * app shell — so "expect 404" would fail even when the fix works, and "expect
 * 200" would pass whether or not the file is there. The real signal is the
 * content type: an actual symbols file is served as the
 * `application/octet-stream` default_type, while the fallback is `text/html`.
 * Collapsing to the fallback is therefore proof the file is gone.
 *
 * This is the same vacuous-200 hazard the sibling specs guard against, arrived
 * at from the opposite direction: here the fallback is the pass condition
 * rather than the failure.
 */
test("the CanvasKit .symbols tables are not shipped in the image", async ({ page }) => {
  await gotoSameOriginDocument(page);

  const probes = [
    "/canvaskit/canvaskit.js.symbols",
    "/canvaskit/chromium/canvaskit.js.symbols",
    "/canvaskit/skwasm.js.symbols",
  ];

  const results = await page.evaluate(async (paths: string[]) => {
    const out: { path: string; status: number; type: string; bytes: number }[] = [];
    for (const path of paths) {
      const response = await fetch(path, { cache: "no-store" });
      const body = await response.arrayBuffer();
      out.push({
        path,
        status: response.status,
        type: response.headers.get("content-type") ?? "",
        bytes: body.byteLength,
      });
    }
    return out;
  }, probes);

  // Sanity: the app shell really is what came back, so a broken origin (which
  // would also "not be a symbols file") cannot make this pass.
  const shell = await page.evaluate(async () => {
    const response = await fetch("/index.html", { cache: "no-store" });
    return (await response.text()).length;
  });
  expect(shell, "the SPA fallback document itself should be non-trivial").toBeGreaterThan(200);

  for (const result of results) {
    expect(
      result.type,
      `${result.path} should collapse to the SPA fallback, not serve a symbols table`,
    ).toContain("text/html");
    expect(
      result.bytes,
      `${result.path} returned ${result.bytes} B — a real symbols table is ~1 MB, ` +
        `so this looks like the file is still in the image`,
    ).toBeLessThan(100_000);
  }
});
