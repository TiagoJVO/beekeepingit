import { test, expect, Page } from "@playwright/test";

/**
 * The M0 walking-skeleton end-to-end test (#23 §7.3):
 *   log in (Keycloak OIDC) → create an apiary → go offline → edit it →
 *   verify the edit is local-only → reconnect → assert it synced to the
 *   server → reload and assert the local state converged.
 *
 * The PWA is Flutter Web. Flutter only exposes an accessibility DOM (which
 * Playwright can query) once semantics are enabled, so `enableSemantics`
 * clicks Flutter's a11y placeholder first. If canvas semantics prove brittle,
 * the documented fallback is Flutter `integration_test` (design §7.3).
 */

const TEST_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const TEST_PASS = process.env.E2E_PASS ?? "dev-password123";
const apiaryName = `Encosta Nova ${Date.now()}`;

async function enableSemantics(page: Page) {
  // Flutter renders a hidden "Enable accessibility" placeholder; clicking it
  // builds the semantics DOM Playwright selects against.
  const placeholder = page.locator("flt-semantics-placeholder");
  if (await placeholder.count()) {
    await placeholder.first().click({ force: true }).catch(() => {});
  }
}

async function login(page: Page) {
  await page.goto("/");
  await enableSemantics(page);
  await page.getByText("Sign in with Keycloak").click();

  // Keycloak's login page is standard HTML.
  await page.locator("#username").fill(TEST_USER);
  await page.locator("#password").fill(TEST_PASS);
  await page.locator("#kc-login").click();

  // Back on the PWA (apiaries list).
  await page.waitForURL(/\/apiaries/);
  await enableSemantics(page);
  await expect(page.getByText("Apiaries")).toBeVisible();
}

test("login → create → offline edit → sync", async ({ page, context }) => {
  // Capture the Keycloak access token from the app's own requests (the
  // realm disallows direct grant, so we don't mint one out-of-band).
  let capturedToken = "";
  page.on("request", (req) => {
    const auth = req.headers()["authorization"];
    if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
      capturedToken = auth.slice("Bearer ".length);
    }
  });

  await login(page);

  // ── Create an apiary ──────────────────────────────────────────────────
  await page.getByText("Add apiary").click();
  await enableSemantics(page);
  await page.getByLabel("Name").click();
  await page.keyboard.type(apiaryName);
  await page.getByLabel("Number of hives").click();
  await page.keyboard.type("0");
  await page.getByText("Save", { exact: true }).click();

  await expect(page.getByText(apiaryName)).toBeVisible();

  // ── Go offline and edit ───────────────────────────────────────────────
  await context.setOffline(true);
  await page.getByText(apiaryName).click();
  await enableSemantics(page);
  const hives = page.getByLabel("Number of hives");
  await hives.click();
  await page.keyboard.press("Control+A");
  await page.keyboard.type("12");
  await page.getByText("Save", { exact: true }).click();

  // The edit is applied locally while offline (local-first, FR-OF-1).
  await expect(page.getByText("12 hives")).toBeVisible();

  // ── Reconnect → the queued change syncs ───────────────────────────────
  await context.setOffline(false);

  // Assert server-side: the edit reached the apiaries service.
  await expect
    .poll(async () => serverHiveCount(page, capturedToken, apiaryName), { timeout: 30_000 })
    .toBe(12);

  // ── Reload → local state converged (#23 AC) ───────────────────────────
  await page.reload();
  await enableSemantics(page);
  await expect(page.getByText(apiaryName)).toBeVisible();
  await expect(page.getByText("12 hives")).toBeVisible();
});

async function serverHiveCount(page: Page, token: string, name: string): Promise<number | null> {
  const apiURL = process.env.E2E_API_URL ?? "";
  const res = await page.request.get(`${apiURL}/v1/apiaries`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    ignoreHTTPSErrors: true,
  });
  if (!res.ok()) return null;
  const body = await res.json();
  const found = (body.data ?? []).find((a: { name: string }) => a.name === name);
  return found ? found.hive_count : null;
}
