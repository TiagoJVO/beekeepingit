import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright config for the walking-skeleton e2e (#23 §7.3). Points at the
 * deployed PWA through the gateway; override with env vars in CI / local runs.
 *
 *   E2E_BASE_URL   the PWA origin (through the gateway)   default: https://keycloak.beekeepingit.local:8443
 *   E2E_API_URL    gateway base for server-side asserts   default: same as base
 */
const baseURL = process.env.E2E_BASE_URL ?? "https://keycloak.beekeepingit.local:8443";

// Map the gateway host to loopback in the browser itself (no /etc/hosts edit
// needed) so `keycloak.beekeepingit.local` reaches the k3d host port. Override
// E2E_HOST_MAP to point elsewhere.
const hostMap = process.env.E2E_HOST_MAP ?? "MAP keycloak.beekeepingit.local 127.0.0.1";

export default defineConfig({
  testDir: "./tests",
  timeout: 120_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL,
    // Dev cluster uses a self-signed cert.
    ignoreHTTPSErrors: true,
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
