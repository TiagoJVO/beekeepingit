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
  // Flutter builds its semantics DOM (what Playwright selects against) only
  // after its "Enable accessibility" placeholder is activated. A direct DOM
  // click fires the handler regardless of the element's (1x1, offscreen)
  // geometry. Reappears after each full page load (e.g. the OIDC redirect).
  //
  // Wait for Flutter to actually bootstrap first: over HTTPS (cross-origin
  // isolated), the PowerSync/SQLite worker startup pushes first paint out, so
  // clicking the placeholder immediately after goto() lands before it exists
  // and no tree is built. Wait for the glass pane, click, then poll until the
  // semantic tree materializes — no fixed sleeps.
  await page.waitForSelector("flt-glass-pane, flutter-view", { timeout: 30_000 }).catch(() => {});
  await page
    .evaluate(() => {
      const el =
        (document.querySelector("flt-semantics-placeholder") as HTMLElement | null) ??
        (document.querySelector('[aria-label="Enable accessibility"]') as HTMLElement | null);
      el?.click();
    })
    .catch(() => {});
  await page
    .waitForFunction(() => document.querySelectorAll("flt-semantics").length > 1, null, {
      timeout: 15_000,
    })
    .catch(() => {});
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
  await expect(page.getByRole("heading", { name: "Apiaries" })).toBeVisible();
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
  await page.getByRole("button", { name: "Add apiary" }).click();
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
  // Clear the field reliably before typing (Flutter web can drop the first
  // keystroke after a select-all), then type digit-by-digit.
  await page.keyboard.press("Control+A");
  await page.keyboard.press("Delete");
  await page.keyboard.press("Backspace");
  await page.keyboard.type("12", { delay: 80 });
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
  // Run the request INSIDE the page: same-origin (no CORS) and it uses the
  // browser's host-resolver rule, unlike Playwright's Node-side request context.
  return page.evaluate(
    async ({ apiURL, token, name }) => {
      const res = await fetch(`${apiURL}/v1/apiaries`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!res.ok) return null;
      const body = await res.json();
      const found = (body.data ?? []).find((a: { name: string }) => a.name === name);
      return found ? (found.hive_count as number) : null;
    },
    { apiURL, token, name },
  );
}
