import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright config for the walking-skeleton e2e (#23 §7.3). Points at the
 * deployed PWA through the gateway; override with env vars in CI / local runs.
 *
 *   E2E_BASE_URL   the PWA origin (through the gateway)   default: https://keycloak.beekeepingit.local:8443
 *   E2E_API_URL    gateway base for server-side asserts   default: same as base
 */
const baseURL = process.env.E2E_BASE_URL ?? "https://keycloak.beekeepingit.local:8443";

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
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
