import { test, expect, Page } from "@playwright/test";

/**
 * The M0 walking-skeleton end-to-end test (#23 §7.3):
 *   log in (OIDC, provider-agnostic) → create an apiary → go offline → edit it →
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

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// The apiaries list row for `name`, as a Flutter semantics button. Scoped by the
// unique name because download sync legitimately fills the list with the org's
// other apiaries (several of which also read "12 hives").
const apiaryRow = (page: Page, name: string) =>
  page.getByRole("button", { name: new RegExp(escapeRe(name)) });

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

// Provider-agnostic IdP login. The app only redirects to the discovered OIDC
// provider, so this test must not depend on any one provider's page markup
// (fixed element ids like `#username`/`#kc-login`, etc.). Locate fields by
// their accessible label/role — Playwright pierces shadow DOM (Authentik
// renders its login as lit web components) — and tolerate a two-step
// (identify → password) flow: submit after the identifier if the password
// field isn't shown yet.
const submitButton = (page: Page) =>
  page.getByRole("button", { name: /log ?in|sign in|continue|next/i });

async function fillIfPresent(
  page: Page,
  locator: ReturnType<Page["getByLabel"]>,
  value: string,
): Promise<boolean> {
  try {
    await locator.first().waitFor({ state: "visible", timeout: 15_000 });
  } catch {
    return false;
  }
  await locator.first().fill(value);
  return true;
}

async function login(page: Page) {
  await page.goto("/");
  await enableSemantics(page);
  await page.getByRole("button", { name: /sign in/i }).click();

  // ── Step 1: identifier (username/email) ───────────────────────────────
  await fillIfPresent(page, page.getByLabel(/username|email/i), TEST_USER);

  // Two-step providers (e.g. Authentik) show the password only after the
  // identifier is submitted; a single-step page already has it, so only click
  // through if the password field isn't visible yet.
  const password = page.getByLabel(/password/i);
  if (!(await password.first().isVisible().catch(() => false))) {
    await submitButton(page).first().click();
  }

  // ── Step 2: password ──────────────────────────────────────────────────
  await fillIfPresent(page, password, TEST_PASS);
  await submitButton(page).first().click();

  // Back on the PWA (apiaries list).
  await page.waitForURL(/\/apiaries/);
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Apiaries" })).toBeVisible();
}

test("login → create → offline edit → sync", async ({ page, context, browser }) => {
  // Capture the OIDC access token from the app's own requests (the provider
  // disallows direct grant, so we don't mint one out-of-band).
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
  // Tapping the list row now opens the read-only detail screen (FR-AP-7,
  // #32) rather than the edit form directly — reach the form via its edit
  // action.
  await context.setOffline(true);
  await page.getByText(apiaryName).click();
  await enableSemantics(page);
  await page.getByRole("button", { name: "Edit apiary" }).click();
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
  await expect(apiaryRow(page, apiaryName)).toContainText("12 hives");

  // ── Reconnect → the queued change syncs ───────────────────────────────
  await context.setOffline(false);

  // Assert server-side: the edit reached the apiaries service.
  await expect
    .poll(async () => serverHiveCount(page, capturedToken, apiaryName), { timeout: 30_000 })
    .toBe(12);

  // ── Reload → local state converged (#23 AC) ───────────────────────────
  await page.reload();
  await enableSemantics(page);
  await expect(apiaryRow(page, apiaryName)).toContainText("12 hives");

  // ── A second, fresh client converges via download sync ────────────────
  // Guards the server→client half of sync: a brand-new context has an empty
  // local SQLite, so it can only show this apiary if PowerSync *downloaded* it
  // from the server (not local persistence). This is what catches a broken
  // download stream — e.g. the gateway/endpoint bugs that let the reload above
  // still pass on stale local state (#23).
  const fresh = await browser.newContext();
  try {
    const p2 = await fresh.newPage();
    await login(p2);
    await expect(apiaryRow(p2, apiaryName)).toBeVisible({ timeout: 30_000 });
    await expect(apiaryRow(p2, apiaryName)).toContainText("12 hives");
  } finally {
    await fresh.close();
  }
});

test("logout revokes the session — a reload does not silently re-authenticate (#24)", async ({
  page,
}) => {
  // The most faithful check of the real OIDC end-session round trip
  // (auth_controller_test.dart's unit tests stub the network; this exercises
  // the actual front-channel RP-initiated logout against the live provider,
  // which clears local state, redirects to end_session_endpoint with the
  // id_token_hint, then back to the app's post_logout_redirect_uri).
  await login(page);

  await page.getByRole("button", { name: "Sign out" }).click();

  // The app-side session is cleared and (after the end-session round trip
  // returns to the app origin) the router sends us back to /login.
  await page.waitForURL(/\/login/);
  await enableSemantics(page);
  await expect(page.getByRole("button", { name: /sign in/i })).toBeVisible();

  // A fresh reload must NOT silently restore the session (no refresh token
  // survives logout, and the provider SSO cookie/session was ended
  // server-side, not just locally forgotten) — still on /login, not bounced
  // back into the app.
  await page.reload();
  await enableSemantics(page);
  await expect(page.getByRole("button", { name: /sign in/i })).toBeVisible();
  expect(page.url()).toMatch(/\/login/);
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
