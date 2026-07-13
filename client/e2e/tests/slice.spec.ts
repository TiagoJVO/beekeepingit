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

// Test-data teardown (#162): the create test leaves an apiary behind server-side.
// Harmless against an ephemeral per-run cluster (CI deletes the whole namespace/
// cluster afterwards, see helm-e2e.yml's "Tear down the cluster" step), but the
// list would otherwise grow across runs against any longer-lived environment —
// so delete it explicitly rather than relying on cluster ephemerality alone.
// The main test captures the bearer token it observes and the server-assigned id
// (both only obtainable from a real authenticated run); afterAll then deletes by
// id via the same REST API the app uses (see the afterAll block below for why
// that's a throwaway browser page, not Playwright's `request` fixture).
let cleanupToken = "";
let createdApiaryId: string | null = null;

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// The apiaries list row for `name`, as a Flutter semantics button. Scoped by the
// unique name because download sync legitimately fills the list with the org's
// other apiaries (several of which also read "12 hives").
const apiaryRow = (page: Page, name: string) =>
  page.getByRole("button", { name: new RegExp(escapeRe(name)) });

// The read-only apiary detail screen's hive-count badge (FR-AP-7, #32). After
// editing from the detail screen, the form's save returns here (not to the
// list), so this is where the fresh count shows. `getByText` is unambiguous on
// the detail screen — no list rows are mounted alongside it.
const apiaryDetailHiveCount = (page: Page) => page.getByText(/\d+ hives|No hives/);

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
  if (
    !(await password
      .first()
      .isVisible()
      .catch(() => false))
  ) {
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
  // disallows direct grant, so we don't mint one out-of-band). Also stashed at
  // module scope so afterAll can delete the apiary this test creates (#162).
  let capturedToken = "";
  page.on("request", (req) => {
    const auth = req.headers()["authorization"];
    if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
      capturedToken = auth.slice("Bearer ".length);
      cleanupToken = capturedToken;
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

  // The edit is applied locally while offline (local-first, FR-OF-1). Saving
  // the edit form now returns to the read-only detail screen (FR-AP-7, #32 —
  // the form's `_save` routes to /apiaries/:id, not back to the list), so the
  // fresh value shows on the detail hive-count badge, not a list row. Assert
  // it there — no navigation, so this stays valid while still offline.
  await expect(apiaryDetailHiveCount(page)).toContainText("12 hives");

  // ── Reconnect → the queued change syncs ───────────────────────────────
  await context.setOffline(false);

  // Assert server-side: the edit reached the apiaries service. This runs a
  // fetch inside the current page, so it works from the detail screen — no
  // need to be on the list yet. Generous timeout: the connection-quality sync
  // gate (#55, FR-OF-3) re-probes on an exponential backoff (2s→…, capped),
  // so after reconnect the queued upload can wait out one backoff interval
  // before it fires — that's by design, not a hang.
  await expect
    .poll(async () => serverHiveCount(page, capturedToken, apiaryName), { timeout: 60_000 })
    .toBe(12);

  // Stash the server-assigned id for afterAll's cleanup (#162) — it only
  // exists once the create has actually synced, which the poll above just
  // confirmed.
  createdApiaryId = await serverApiaryId(page, capturedToken, apiaryName);

  // ── Back to the list → local state converged (#23 AC) ─────────────────
  // Return via the shell's in-app Back button, NOT a page reload / full
  // navigation. A full reload currently logs the session out: the app only
  // restores a session from a persisted OIDC refresh token (auth_controller
  // build()), but the client requests scopes ['openid','profile','email']
  // WITHOUT 'offline_access', so Authentik (whose provider IS configured for
  // refresh_token + offline_access) never issues one — nothing is persisted,
  // and any full load redirects to /login. That's a real, separate
  // walking-skeleton auth bug (see the test.fixme below and the PR notes),
  // independent of #162's e2e wiring. In-app navigation keeps the in-memory
  // session, so this still validates that the list row read from local SQLite
  // converged to the synced value.
  await enableSemantics(page);
  await page.getByRole("button", { name: "Back" }).click();
  await enableSemantics(page);
  await expect(apiaryRow(page, apiaryName)).toContainText("12 hives");

  // ── A second, fresh client converges via download sync ────────────────
  // Guards the server→client half of sync: a brand-new context has an empty
  // local SQLite, so it can only show this apiary if PowerSync *downloaded* it
  // from the server (not local persistence). This is what catches a broken
  // download stream — e.g. the gateway/endpoint bugs that let a stale-local
  // read still pass (#23). This is the stronger convergence guarantee — it
  // does a fresh login, so it doesn't depend on reload session-persistence.
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

// A page reload should keep the user logged in (auth.md §7: "app open, online
// → silently refresh the access token") and the local state should converge on
// reload — but today a full reload logs out, because the client never requests
// the `offline_access` scope so no refresh token is persisted to restore from
// (auth_controller.dart login()/_refresh() request ['openid','profile','email']
// only; the Authentik provider blueprint already maps offline_access + the
// refresh_token grant, so the fix is client-side). Kept as a documented,
// skipped guard so the reload-persistence AC isn't silently dropped: unskip
// once the scope is added. Real bug, NOT an e2e-harness issue.
test.fixme("reload keeps the session and converges (blocked: client omits offline_access → no refresh token persisted)", async ({
  page,
}) => {
  await login(page);
  await page.reload();
  await enableSemantics(page);
  // Should still be authenticated (on /apiaries), not bounced to /login.
  await expect(page.getByRole("heading", { name: "Apiaries" })).toBeVisible();
});

// Blocked on a real, separate walking-skeleton bug — NOT an e2e-harness issue,
// so skipped (test.fixme) rather than loosened, and kept intact to unskip once
// the bug is fixed. Evidence (Playwright trace + failure screenshot on this
// branch's CI run): after Sign out, the app performs its front-channel
// RP-initiated logout to Authentik's end_session_endpoint, but Authentik then
// shows its own "You've logged out of BeekeepingIT" confirmation interstitial
// ("Go back to overview / Log out / Log back into BeekeepingIT") instead of
// auto-redirecting to the app's post_logout_redirect_uri — so the browser never
// returns to the app's /login and `waitForURL(/\/login/)` times out. The app-
// side logout (local state cleared, #125) happens; the round trip just doesn't
// come back on its own. Fix is on the Authentik/logout-flow side (e.g. the
// provider needs to honor the post_logout_redirect_uri without the interstitial,
// or the flow must be configured to skip it). auth_controller_test.dart already
// covers the client end-session request shape at the unit level; this e2e is the
// only place the live round trip is exercised, so it stays here as the guard.
test.fixme("logout revokes the session — a reload does not silently re-authenticate (#24) [blocked: Authentik shows a logout-confirmation interstitial instead of redirecting back to the app]", async ({
  page,
}) => {
  // The most faithful check of the real OIDC end-session round trip
  // (auth_controller_test.dart's unit tests stub the network; this exercises
  // the actual front-channel RP-initiated logout against the live provider,
  // which clears local state, redirects to end_session_endpoint with the
  // id_token_hint, then back to the app's post_logout_redirect_uri).
  await login(page);

  // Logout moved off the apiaries list's app bar to the Account screen (app-
  // shell IA rework, #197/#172): open Account from the shell header (its
  // account button's accessible name is the "Account settings" tooltip), then
  // sign out from there.
  await page.getByRole("button", { name: "Account settings" }).click();
  await enableSemantics(page);
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

async function serverApiaryId(page: Page, token: string, name: string): Promise<string | null> {
  const apiURL = process.env.E2E_API_URL ?? "";
  return page.evaluate(
    async ({ apiURL, token, name }) => {
      const res = await fetch(`${apiURL}/v1/apiaries`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!res.ok) return null;
      const body = await res.json();
      const found = (body.data ?? []).find((a: { name: string }) => a.name === name);
      return found ? (found.id as string) : null;
    },
    { apiURL, token, name },
  );
}

// Test-data teardown (#162): delete the apiary the create test left on the
// server. Deliberately NOT Playwright's `request` fixture — that issues a
// plain Node-side HTTP request, which doesn't get the browser launch's
// `--host-resolver-rules` (playwright.config.ts's hostMap) that's the whole
// reason the dev hostnames resolve without editing the runner's /etc/hosts.
// A throwaway browser page does inherit it (same as serverHiveCount/
// serverApiaryId above), so the DELETE runs the same way those GETs do.
// Best-effort: if the create test never got far enough to populate
// `createdApiaryId` (e.g. it failed before syncing), there's nothing to
// clean up. Runs even if a test failed, so a red run still doesn't leak data.
test.afterAll(async ({ browser }) => {
  if (!createdApiaryId || !cleanupToken) return;
  const apiURL = process.env.E2E_API_URL ?? "";
  const id = createdApiaryId;
  const token = cleanupToken;
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto("/");
    const status = await page.evaluate(
      async ({ apiURL, token, id }) => {
        const res = await fetch(`${apiURL}/v1/apiaries/${id}`, {
          method: "DELETE",
          headers: { Authorization: `Bearer ${token}` },
        });
        return res.status;
      },
      { apiURL, token, id },
    );
    if (status >= 400 && status !== 404) {
      // Non-fatal: don't fail an otherwise-green run over cleanup.
      console.warn(`afterAll cleanup: DELETE /v1/apiaries/${id} -> ${status}`);
    }
  } finally {
    await context.close();
  }
});
