import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright config for the walking-skeleton e2e (#23 §7.3). Points at the
 * deployed PWA through the gateway; override with env vars in CI / local runs.
 *
 *   E2E_BASE_URL   the PWA origin (through the gateway)   default: https://app.beekeepingit.local:8443
 *   E2E_API_URL    gateway base for server-side asserts   default: same as base
 */
const baseURL = process.env.E2E_BASE_URL ?? "https://app.beekeepingit.local:8443";

// Map both the app host (PWA/APIs/sync) and the auth host (the OIDC provider,
// on its own origin — see docs/architecture/oidc-integration.md §2) to loopback
// in the browser itself (no /etc/hosts edit needed) so the OIDC redirect
// resolves to the k3d host port. Override E2E_HOST_MAP to point elsewhere.
const hostMap =
  process.env.E2E_HOST_MAP ??
  "MAP app.beekeepingit.local 127.0.0.1, MAP auth.beekeepingit.local 127.0.0.1";

export default defineConfig({
  testDir: "./tests",
  // The create→offline-edit→sync test does two full OIDC logins (the main flow
  // + a fresh-client convergence check), each of which may retry a cold-stack
  // "Bad Gateway" (gotoAppRoot) or wait out a slow Authentik first paint, plus
  // an offline edit, a "Sync now" nudge, and a fresh-client download — under CI
  // load against a freshly-booted stack that adds up. 240s gives the explicit
  // per-step waits room to resolve without the whole test timing out mid-step.
  timeout: 240_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL,
    // Dev cluster uses a self-signed cert.
    ignoreHTTPSErrors: true,
    // Location is mandatory on the apiary form (#341, FR-AP-7), and the form's
    // "use current location" action goes through `geolocator` →
    // `navigator.geolocation`. Granting the permission up front (and pinning a
    // fixed coordinate) makes that path deterministic — no permission prompt to
    // dismiss, no real device location — so the create step has a reliable
    // fallback if the embedded map's canvas tap doesn't take under headless
    // chromium. The coordinate is mainland Portugal, matching the app's own
    // default map center (apiary_form_screen.dart's `_pickerFallbackCenter`).
    permissions: ["geolocation"],
    geolocation: { latitude: 39.5, longitude: -8.0 },
    // The OIDC callback + Flutter re-bootstrap is a full page load that can be
    // slow on a cold stack; the default 30s navigation budget is tight, so
    // raise it for waitForURL/goto across the suite.
    navigationTimeout: 60_000,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    launchOptions: {
      args: [
        `--host-resolver-rules=${hostMap}`,
        // The dev gateway serves the PWA over HTTPS with a self-signed cert;
        // accept it. HTTPS makes the origin trustworthy, so the PWA's COOP/COEP
        // headers are honored → cross-origin isolation → PowerSync's web sync
        // worker (which needs SharedArrayBuffer) starts. (Do NOT disable site
        // isolation — cross-origin isolation depends on it.)
        "--ignore-certificate-errors",
      ],
    },
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
