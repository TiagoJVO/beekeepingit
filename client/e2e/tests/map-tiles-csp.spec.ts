import { test, expect } from "@playwright/test";
import { gotoSameOriginDocument } from "./helpers";

/**
 * The map's tile hosts survive the CSP being ENFORCED (#671, NFR-SEC-1, FR-AP-3,
 * D-16, NFR-TST-1).
 *
 * `flutter_map` fetches every tile through `package:http`, whose web
 * implementation is an `XMLHttpRequest` — so on the web a tile is governed by
 * the CSP's `connect-src`, not `img-src`, even though the bytes end up in an
 * `ImageProvider`. Until #671 `connect-src` named neither tile host. That was
 * invisible only because the deployed header is
 * `Content-Security-Policy-Report-Only`: flipping it to the enforcing name,
 * which is the entire point of #462, would have blanked the apiary map, the
 * embedded location picker and the full-screen picker at once — `nginx -t`
 * green, pod Ready, nothing red.
 *
 * WHY THE POLICY IS RE-SERVED AS ENFORCING RATHER THAN READ. A report-only
 * header does not block, so "the app still worked" proves nothing about the day
 * #462 lands. This spec therefore takes the policy string the PWA container
 * ACTUALLY SHIPS, serves a document from the app's own origin carrying that
 * exact string under the enforcing header name, and makes the browser decide.
 * It is the deployed policy, enforced, in a real browser, against the image
 * built from this commit — not a restatement of it.
 *
 * WHY IT DOES NOT DRIVE THE FLUTTER MAP ITSELF. Every map view is behind an
 * OIDC login, and the property under test is not "does flutter_map render" (six
 * widget tests already cover that, `client/test/apiary_map_screen_test.dart`
 * among them) but "does the browser permit the request flutter_map makes". So
 * this spec issues that request directly: the same URLs, from the same origin,
 * under the same policy. `client/test/map_tile_csp_test.dart` is the other half
 * — it holds `connect-src` against the very constants the three map screens
 * pass to `TileLayer`, so the URLs asserted here cannot drift from the URLs the
 * app uses without that test going red.
 *
 * WHY NOTHING LEAVES CI. Every third-party URL below is fulfilled by Playwright
 * with a stub response, so no request reaches Esri or the OSM Foundation from a
 * runner — which is the point of #671's second half, and would be a poor thing
 * for the test guarding it to do. That interception is also the MECHANISM: a
 * CSP-blocked request never reaches the network layer, so a route that fires is
 * itself evidence the policy allowed it, and a route that never fires is why
 * the negative control's `fetch()` rejects. Two limits that follow from that,
 * so nobody over-reads the guarantee: the stubs answer hop one, so a
 * provider-side REDIRECT to an unlisted host — which CSP re-checks on every hop
 * and would blank the map just as surely — cannot be caught here; and the
 * third-party routes are registered after the app-origin document is fetched,
 * so "nothing leaves the runner" leans on the boot itself calling no third
 * party, which is `same-origin-boot.spec.ts`'s claim, not this one's.
 */

// The tile endpoints the app renders from, in the {z}/{x}/{y} order each
// provider uses (Esri's ArcGIS REST scheme puts the row before the column).
// Coordinates are 0/0/0 — the whole world at zoom 0, which is the one tile that
// discloses nothing about anybody — and the requests are intercepted anyway.
const tileProbes = [
  {
    name: "Esri World Imagery (default satellite layer)",
    origin: "https://server.arcgisonline.com",
    url: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/0/0/0",
  },
  {
    name: "OpenStreetMap (streets layer)",
    origin: "https://tile.openstreetmap.org",
    url: "https://tile.openstreetmap.org/0/0/0.png",
  },
];

// A host the policy must NOT permit. Without this, a policy that silently
// failed to apply at all would satisfy every positive assertion above it.
//
// A `.invalid` host (RFC 6761 — reserved, guaranteed never to resolve) rather
// than a real one this app used to call: fonts.gstatic.com would have read
// better, but #673 is actively weighing putting it BACK for emoji fallback, and
// a negative control that a legitimate future change turns red — with a failure
// message about map tiles — is a trap. This host can never be allow-listed. It
// is still route-stubbed, so a policy that failed to block would fulfil with a
// 200 and fail loudly here, rather than "failing" for want of DNS and passing.
const blockedProbe = {
  origin: "https://csp-negative-control.invalid",
  url: "https://csp-negative-control.invalid/never-allow-listed.png",
};

// A path that does not exist in the bundle; Playwright answers it before nginx
// ever sees it. Same origin as the app, which is what makes `'self'` and the
// tile entries mean here what they mean in production.
const PROBE_PATH = "/__csp-probe-671";

// A 1x1 transparent PNG — a plausible tile body, small enough to inline.
const stubTile = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

interface ProbeResult {
  url: string;
  ok: boolean;
  error: string | null;
}

interface Violation {
  blockedURI: string;
  violatedDirective: string;
}

test.describe("map tiles under an enforcing CSP (#671)", () => {
  test("the shipped policy permits every tile host and still blocks everything else", async ({
    page,
  }) => {
    // A boot, one ~1.4 MB same-origin read and four intercepted requests. The
    // suite default is 240s; 180s is deliberate slack over a cold k3d gateway
    // and no more, matching what compression.spec.ts budgets for a comparable
    // shape. (Not left implicit: a spec that can only fail by timing out tells
    // the next reader nothing about what it expected to cost.)
    test.setTimeout(180_000);

    // ── 1. The policy under test is the one the container ships ──────────
    const appDocument = await gotoSameOriginDocument(page);
    const headers = appDocument.headers();
    // Report-only TODAY, and this spec is the reason it can stop being: #462
    // flips the header name once a real browser has validated the policy, which
    // is what happens below. So take whichever name the container sends,
    // preferring the enforcing one — after #462 lands this spec keeps working
    // and simply stops having to re-serve anything to make the point.
    const enforced = headers["content-security-policy"];
    const policy = enforced ?? headers["content-security-policy-report-only"] ?? "";

    expect(
      policy,
      "the PWA container sent no Content-Security-Policy header under either name — " +
        "everything below would be enforcing a policy this test invented",
    ).not.toBe("");
    expect(policy).toContain("connect-src");
    console.log(
      `[#671] policy under test came from Content-Security-Policy` +
        `${enforced ? "" : "-Report-Only"}`,
    );

    // ── 2. Positive evidence: the bundle really does call these hosts ─────
    // Without this, renaming a tile provider in the app would leave this spec
    // green while covering a policy entry nothing uses. Read from the DEPLOYED
    // bundle, in the page, because only the browser can resolve the app host —
    // and matched IN the page, because shipping 4.4 MB of JS back over CDP to
    // run `includes` on it in Node would be absurd.
    const inBundle = await page.evaluate(
      async (origins: string[]) => {
        const source = await fetch("/main.dart.js").then((response) => response.text());
        return origins.map((origin) => source.includes(origin));
      },
      tileProbes.map((probe) => probe.origin),
    );

    tileProbes.forEach((probe, index) => {
      expect(
        inBundle[index],
        `the deployed app bundle contains no reference to ${probe.origin} — ` +
          `${probe.name} is no longer a tile source, so allow-listing it proves nothing`,
      ).toBe(true);
    });

    // ── 3. Serve a same-origin document carrying that policy, ENFORCED ────
    // COOP/COEP are copied across as well, so the probe is a replica of the
    // production document rather than only its CSP. `require-corp` is the
    // second gate a cross-origin tile has to clear, and a cors-mode XHR clears
    // it on the CORS check alone (no Cross-Origin-Resource-Policy needed, and
    // neither provider sends one) — carrying the header keeps that true by
    // observation instead of by argument.
    const isolation = {
      "cross-origin-opener-policy": headers["cross-origin-opener-policy"] ?? "same-origin",
      "cross-origin-embedder-policy": headers["cross-origin-embedder-policy"] ?? "require-corp",
    };
    await page.route(`**${PROBE_PATH}`, (route) =>
      route.fulfill({
        status: 200,
        contentType: "text/html; charset=utf-8",
        headers: { "content-security-policy": policy, ...isolation },
        // No inline script: `script-src 'self'` would block one, and the probe
        // runs through page.evaluate anyway.
        body: "<!doctype html><title>#671 CSP probe</title><p>csp probe</p>",
      }),
    );

    // Stub every third-party URL, so a permitted request stops at Playwright.
    for (const probe of [...tileProbes, blockedProbe]) {
      await page.route(`${probe.origin}/**`, (route) =>
        route.fulfill({
          status: 200,
          contentType: "image/png",
          // The real tile servers answer XHR with CORS; the stub must too, or a
          // rejected fetch would be ambiguous between "CSP blocked it" and
          // "CORS blocked it".
          headers: { "access-control-allow-origin": "*" },
          body: stubTile,
        }),
      );
    }

    await page.goto(PROBE_PATH, { waitUntil: "domcontentloaded" });

    // ── 4. Let the browser decide ─────────────────────────────────────────
    const probed: { results: ProbeResult[]; violations: Violation[] } = await page.evaluate(
      async (urls: string[]) => {
        const violations: Violation[] = [];
        document.addEventListener("securitypolicyviolation", (event) => {
          violations.push({
            blockedURI: event.blockedURI,
            violatedDirective: event.violatedDirective,
          });
        });

        const results: ProbeResult[] = [];
        for (const url of urls) {
          try {
            const response = await fetch(url);
            results.push({ url, ok: response.ok, error: null });
          } catch (error) {
            results.push({ url, ok: false, error: String(error) });
          }
        }
        // Violation events are dispatched asynchronously; give them a beat.
        await new Promise((resolve) => setTimeout(resolve, 500));
        return { results, violations };
      },
      [...tileProbes.map((probe) => probe.url), blockedProbe.url],
    );

    const resultFor = (url: string) => {
      const result = probed.results.find((candidate) => candidate.url === url);
      expect(result, `no probe result recorded for ${url}`).toBeDefined();
      return result as ProbeResult;
    };
    const allViolations = probed.violations;

    for (const probe of tileProbes) {
      const result = resultFor(probe.url);
      expect(
        result.ok,
        `${probe.name} was refused under the enforced policy (${result.error ?? "not ok"}). ` +
          `connect-src must name ${probe.origin} — flutter_map fetches tiles over XHR, so ` +
          `img-src does not cover them. Enforcing this policy would blank every map view.`,
      ).toBe(true);
      expect(
        allViolations.filter((violation) => violation.blockedURI.startsWith(probe.origin)),
        `${probe.origin} produced a CSP violation report under the shipped policy`,
      ).toEqual([]);
    }

    // ── 5. The negative control ───────────────────────────────────────────
    const blocked = resultFor(blockedProbe.url);
    expect(
      blocked.ok,
      "an un-allow-listed host was reachable — the policy is not being enforced at all, so " +
        "nothing above is evidence of anything",
    ).toBe(false);
    expect(
      allViolations.some(
        (violation) =>
          violation.blockedURI.startsWith(blockedProbe.origin) &&
          violation.violatedDirective.includes("connect-src"),
      ),
      `expected a connect-src violation for ${blockedProbe.origin}, got ` +
        JSON.stringify(allViolations),
    ).toBe(true);
  });
});
