import { test, expect } from "@playwright/test";
import { enableSemantics, gotoAppRoot } from "./helpers";

/**
 * Boot must not touch a third party (#620, NFR-CMP, FR-OF-1, C-2, NFR-TST-1).
 *
 * Until #620 every cold load fetched
 * `https://fonts.gstatic.com/s/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2`.
 * The web engine has a default font family whose NAME it hardcodes — `Roboto` —
 * and it downloads one from `fontFallbackBaseUrl` (default
 * `https://fonts.gstatic.com/s/`) whenever `FontManifest.json` declares no such
 * family. That put every user's IP address in front of Google on the boot path
 * of an app whose premise is weak signal, and it contradicted the CDN-free
 * claim `client/nginx.conf` was shipping its CSP on.
 *
 * `client/test/fonts_local_fallback_test.dart` pins the two settings that fix
 * it (the bundled `Roboto` family, and `fontFallbackBaseUrl` pinned to a
 * relative path). Only a real browser against the real bundle can prove the
 * *outcome*, which is what this spec is for.
 *
 * Deliberately no login: the bug was on the pre-login boot path, and keeping the
 * spec to a cold page load makes a failure unambiguous — a request that shows up
 * here came from the engine, not from something a test drove.
 */

// Hosts this deployment legitimately owns. The app host serves the PWA, its
// APIs and the PowerSync stream; the auth host is the self-hosted IdP on its own
// origin (docs/architecture/oidc-integration.md §2) that the login screen reads
// OIDC discovery from — both are first-party, both are named in the CSP's
// connect-src, and neither is a CDN. Anything else is a third party by
// definition. (The map's Esri/OSM tile hosts are third parties and are NOT
// allow-listed here — but they are only reached from a signed-in map view, which
// this spec never opens. That exposure is #671, not this one.)
const APP_ORIGIN = process.env.E2E_BASE_URL ?? "https://app.beekeepingit.local:8443";
const AUTH_ORIGIN = process.env.E2E_AUTH_ORIGIN ?? "https://auth.beekeepingit.local:8443";

const firstPartyHosts = new Set([new URL(APP_ORIGIN).host, new URL(AUTH_ORIGIN).host]);

// Schemes the browser never puts on the wire: Flutter inlines small assets as
// data: URIs and starts its workers from blob:.
const inlineSchemes = ["data:", "blob:", "about:", "chrome-extension:"];

test.describe("cold boot stays on our own origins (#620)", () => {
  test("no request leaves the deployment while the app boots and first paints", async ({
    page,
  }) => {
    const requested: string[] = [];
    // Subscribed on the CONTEXT, not the page: a page listener does not see
    // requests a service worker issues, and this spec's whole claim is about
    // everything the browser fetches.
    page.context().on("request", (request) => {
      const url = request.url();
      if (inlineSchemes.some((scheme) => url.startsWith(scheme))) return;
      requested.push(url);
    });

    await gotoAppRoot(page);
    // The Roboto fetch is issued while CanvasKit's font collection initialises —
    // after the glass pane exists (all `gotoAppRoot` waits for) but before the
    // first frame. Drive semantics so the app really renders, then give any
    // trailing request a beat to be observed.
    await enableSemantics(page);
    await page.waitForTimeout(5_000);

    // POSITIVE evidence first, so an absence assertion can never carry this test
    // on its own: if CanvasKit aborted before loading fonts, `offOrigin` would be
    // empty and the real assertion below would pass vacuously.
    expect(
      requested.some((url) => url.includes("assets/FontManifest.json")),
      "the engine never got as far as loading fonts — nothing below is evidence of anything",
    ).toBe(true);
    expect(
      requested.some((url) => url.includes("assets/fonts/Roboto/Roboto-Regular.ttf")),
      "the bundled Roboto was never fetched, so this boot did not take the local-font path",
    ).toBe(true);

    const offOrigin = requested.filter((url) => {
      try {
        return !firstPartyHosts.has(new URL(url).host);
      } catch {
        return false;
      }
    });
    expect(
      offOrigin,
      `boot issued ${offOrigin.length} request(s) outside ${[...firstPartyHosts].join(" / ")}`,
    ).toEqual([]);
  });

  test("the deployed bundle pins the glyph-fallback base URL, and the prefix 404s", async ({
    page,
  }) => {
    await gotoAppRoot(page);

    // Half one: the config really shipped. Nothing on the login screen renders a
    // code point the bundled faces miss, so the runtime fallback path cannot be
    // exercised here — reading it out of the served bootstrap is the honest
    // substitute for asserting a behaviour this spec cannot trigger.
    const bootstrap = await page.evaluate(() =>
      fetch("/flutter_bootstrap.js").then((response) => response.text()),
    );
    expect(bootstrap).toMatch(/fontFallbackBaseUrl\s*:\s*["']font-fallback\/["']/);

    // Half two: nginx routes that prefix itself. Nothing is bundled for the
    // CJK/Arabic/Hebrew families (D-37 scopes the bundled fallback to emoji —
    // see the next test), so the engine must get a 404 and move on rather than
    // the SPA's index.html, which it would download in full and then fail to
    // parse as a font.
    //
    // Fetched from inside the page: only the browser has the
    // `--host-resolver-rules` mapping that makes the app host resolve (see
    // playwright.config.ts), so Playwright's own request context cannot reach it.
    // Only the status is asserted — nginx's built-in 404 body is itself
    // text/html, so content-type does not distinguish it from the SPA fallback;
    // the status does (index.html would be a 200).
    const probe = await page.evaluate(async () => {
      const response = await fetch("/font-fallback/NotoSansSC-Regular.otf");
      return { status: response.status, body: await response.text() };
    });

    expect(probe.status).toBe(404);
    expect(probe.body).not.toContain("flutter_bootstrap.js");
  });

  test("an emoji fallback chunk URL is answered by the bundled face, same-origin (#673)", async ({
    page,
  }) => {
    await gotoAppRoot(page);

    // The exact URL shape the engine builds for an emoji it cannot render:
    // `fontFallbackBaseUrl` + the Noto manifest's entry for the family, which
    // is always one of twelve Google-Fonts subset chunks of `notocoloremoji/`
    // (flutter_web_sdk/.../engine/font_fallback_data.dart, requested by
    // `_FallbackFontDownloadQueue.startDownloads`). The hash below is that
    // manifest's, but its VALUE is deliberately not what is under test:
    // client/nginx.conf maps the family directory, not twelve filenames, so
    // this passes for whatever chunk a future engine asks for. Only a change of
    // family directory would break it — and client/test/emoji_glyph_fallback_
    // test.dart is what catches that against the pinned SDK.
    //
    // Fetched from inside the page for the same reason as the probe above: only
    // the browser has the host-resolver mapping for the app host.
    const chunk = await page.evaluate(async () => {
      const response = await fetch(
        "/font-fallback/notocoloremoji/v32/Yq6P-KqIXTD0t4D9z1ESnKM3-HpFabsE4tq3luCC7p-aXxcn.3.woff2",
      );
      const bytes = new Uint8Array(await response.arrayBuffer());
      return {
        status: response.status,
        type: response.headers.get("content-type"),
        length: bytes.byteLength,
        // TrueType's `sfntVersion`. CanvasKit parses these bytes with FreeType,
        // which sniffs the content rather than the URL, so answering a .woff2
        // request with TrueType is exactly what this deployment intends.
        magic: [...bytes.slice(0, 4)],
      };
    });

    expect(chunk.status).toBe(200);
    expect(chunk.magic).toEqual([0x00, 0x01, 0x00, 0x00]);
    expect(chunk.type).toContain("font/ttf");
    // The whole face, not a stub or the SPA document.
    expect(chunk.length).toBeGreaterThan(500_000);
  });
});
