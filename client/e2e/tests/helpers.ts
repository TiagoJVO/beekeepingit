import { APIRequestContext, Browser, BrowserContext, expect, Page } from "@playwright/test";

/**
 * Shared e2e plumbing, extracted from slice.spec.ts (#361) so the
 * verification-flow spec can reuse the same Flutter-semantics bootstrap and
 * provider-agnostic IdP form driving without duplicating it. The
 * Mailpit/invitation/token helpers moved here from verification.spec.ts when
 * the registration spec (#366) grew the same needs. Behavior is unchanged —
 * see each function's original rationale below.
 */

// Shared env — the same defaults the specs used before extraction. An empty
// API_URL makes the in-page fetches relative (same-origin through the
// gateway), which is the intended default; MAILPIT_URL doubles as the
// verification/registration specs' opt-in switch (helm-e2e.yml port-forwards
// the sink and sets it).
export const MAILPIT_URL = process.env.E2E_MAILPIT_URL ?? "";
export const API_URL = process.env.E2E_API_URL ?? "";

export async function enableSemantics(page: Page) {
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

// Navigate to the app root, tolerating a cold stack. On a freshly-booted k3d
// cluster the gateway/PWA route can transiently answer 502/503/504 (Traefik has
// marked the pod ready, but the route's endpoints/first-request path isn't warm
// yet) — a plain goto() then lands on a static "Bad Gateway" error page that
// never becomes the Flutter app, and every later selector hangs the whole test.
// So: reload until the app actually boots (its glass pane appears), not just
// until goto() resolves. Bounded retries with a short pause.
export async function gotoAppRoot(page: Page) {
  const deadline = Date.now() + 120_000;
  let lastStatus: number | null = null;
  for (;;) {
    const resp = await page.goto("/", { waitUntil: "domcontentloaded" }).catch(() => null);
    lastStatus = resp?.status() ?? lastStatus;
    // A 5xx is the gateway's own error page (no Flutter host element will ever
    // appear) — retry immediately without burning the glass-pane wait on it.
    const serverError = resp != null && resp.status() >= 500;
    if (!serverError) {
      // The app booted if Flutter's host element is present. Give the SPA a
      // beat to attach it after a real 2xx.
      const booted = await page
        .waitForSelector("flt-glass-pane, flutter-view", { timeout: 20_000 })
        .then(() => true)
        .catch(() => false);
      if (booted) return;
    }
    if (Date.now() > deadline) {
      throw new Error(
        `app root never booted (last HTTP status ${lastStatus ?? "unknown"}) — gateway/PWA not ready`,
      );
    }
    await page.waitForTimeout(3_000);
  }
}

// Provider-agnostic IdP login form driving. The app only redirects to the
// discovered OIDC provider, so tests must not depend on any one provider's page
// markup (fixed element ids like `#username`/`#kc-login`, etc.). Locate fields
// by their accessible label/role — Playwright pierces shadow DOM (Authentik
// renders its login as lit web components) — and tolerate a two-step
// (identify → password) flow: submit after the identifier if the password
// field isn't shown yet.
export const submitButton = (page: Page) =>
  page.getByRole("button", { name: /log ?in|sign in|continue|next/i });

export async function fillIfPresent(
  page: Page,
  locator: ReturnType<Page["getByLabel"]>,
  value: string,
  timeout = 30_000,
): Promise<boolean> {
  try {
    await locator.first().waitFor({ state: "visible", timeout });
  } catch {
    return false;
  }
  await locator.first().fill(value);
  return true;
}

/**
 * Starts a login from the app and submits the given credentials on the IdP's
 * form — deliberately WITHOUT asserting where the flow lands afterwards: the
 * walking-skeleton login expects to arrive back on /apiaries, while the
 * verification spec (#361) expects an unverified user to be HELD at the IdP's
 * email stage instead. Each caller asserts its own outcome.
 */
export async function submitIdpCredentials(page: Page, user: string, pass: string) {
  await gotoAppRoot(page);
  await enableSemantics(page);
  // Wait for the app's own Sign in button to be present AND enabled before
  // clicking — on a cold stack the login screen can paint a beat after the
  // glass pane appears. Explicit wait (not just the default click auto-wait)
  // with a generous timeout so a slow first render doesn't burn the whole
  // test budget on a hung click.
  const appSignIn = page.getByRole("button", { name: /sign in/i });
  await appSignIn.waitFor({ state: "visible", timeout: 60_000 });
  await appSignIn.click();

  // The app redirects to Authentik; its login form (lit web components) also
  // needs a beat to render on a cold stack. Wait for the identifier field to
  // be visible before interacting, so we don't click through a half-rendered
  // page. fillIfPresent already tolerates absence, but this makes the wait
  // explicit and generous for the OIDC redirect + Authentik first paint.
  // ── Step 1: identifier (username/email) ───────────────────────────────
  await fillIfPresent(page, page.getByLabel(/username|email/i), user);

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
  await fillIfPresent(page, password, pass);
  await submitButton(page).first().click();
}

/**
 * Decodes the JWT persisted by the app after a completed login and returns its
 * payload. The app stores the OIDC `id_token` in localStorage under
 * `bk.id_token` (auth_controller.dart, #390) — with
 * `include_claims_in_id_token: true` on the provider it carries the same
 * email/email_verified claims as the access token, so e2e can assert the
 * REAL emitted claim values (#361) without intercepting network traffic.
 * Polls until the token appears: the OIDC callback exchange writes it a beat
 * after the app origin loads.
 */
export async function readIdTokenClaims(page: Page): Promise<Record<string, unknown>> {
  await page.waitForFunction(() => window.localStorage.getItem("bk.id_token") !== null, null, {
    timeout: 60_000,
  });
  const idToken = await page.evaluate(() => window.localStorage.getItem("bk.id_token"));
  if (!idToken) throw new Error("bk.id_token disappeared between poll and read");
  const payload = idToken.split(".")[1];
  if (!payload) throw new Error("stored id_token is not a JWT");
  return JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
}

// Extracts the one-time verification link for `recipient` from the Mailpit
// API. The message body is the built-in account-confirmation template whose
// text part carries the bare flow URL on its own line. (The body renders in
// English regardless of user locale on the pinned Authentik 2026.5.4 — see
// the blueprint's i18n note — so no locale-sensitive matching is needed.)
// Always resolves the NEWEST message for the recipient, so callers that need
// a specific email (e.g. the enrollment one, before a login attempt sends a
// second) must poll before triggering more sends.
export async function pollForVerificationLink(
  request: APIRequestContext,
  recipient: string,
): Promise<string> {
  const deadline = Date.now() + 90_000;
  for (;;) {
    const list = await request
      .get(`${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:${recipient}`)}`)
      .catch(() => null);
    if (list?.ok()) {
      const body = (await list.json()) as { messages?: Array<{ ID: string }> };
      const newest = body.messages?.[0];
      if (newest) {
        const full = await request.get(`${MAILPIT_URL}/api/v1/message/${newest.ID}`);
        const text = ((await full.json()) as { Text?: string }).Text ?? "";
        const match = text.match(/https?:\/\/[^\s"<>]+/);
        if (match) return match[0];
      }
    }
    if (Date.now() > deadline) {
      throw new Error(`no verification email for ${recipient} arrived in Mailpit`);
    }
    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }
}

export async function countMessagesTo(
  request: APIRequestContext,
  recipient: string,
): Promise<number> {
  const list = await request.get(
    `${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:${recipient}`)}`,
  );
  const body = (await list.json()) as { messages?: unknown[] };
  return body.messages?.length ?? 0;
}

// A login that completed lands the user back on the app origin — the
// onboarding gate then routes by profile/org state (/profile for a fresh
// user, /apiaries once onboarded/joined). Anything still on the auth host
// means the flow didn't finish.
export async function expectLoginCompleted(page: Page, expectedEmail: string) {
  await page.waitForURL(/app\.beekeepingit\.local|\/profile/, { timeout: 60_000 });
  const claims = await readIdTokenClaims(page);
  expect(claims.email).toBe(expectedEmail);
  expect(claims.email_verified).toBe(true);
}

/**
 * Runs an authenticated JSON call against the domain APIs from inside `page`
 * (which must be on the app origin): same-origin fetch, so it rides the
 * browser's host-resolver rules exactly like slice.spec.ts's serverApiary —
 * Playwright's Node-side `request` fixture would not resolve the dev
 * hostnames.
 */
export async function apiJson(
  page: Page,
  token: string,
  method: string,
  path: string,
  body?: unknown,
): Promise<{ status: number; json: Record<string, unknown> }> {
  return page.evaluate(
    async ({ apiURL, token, method, path, body }) => {
      const res = await fetch(`${apiURL}/v1${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
      return { status: res.status, json };
    },
    { apiURL: API_URL, token, method, path, body },
  );
}

/** The status of the org's invitation for `email`, via the admin's session. */
export async function invitationStatus(
  adminPage: Page,
  adminToken: string,
  orgId: string,
  email: string,
): Promise<string | null> {
  const { status, json } = await apiJson(
    adminPage,
    adminToken,
    "GET",
    `/organizations/${orgId}/invitations`,
  );
  if (status !== 200) return null;
  const rows = (json.data ?? []) as Array<{ email: string; status: string }>;
  return rows.find((row) => row.email === email)?.status ?? null;
}

/**
 * Logs `user` in through the real IdP flow in a fresh context and captures a
 * bearer token from the app's own API traffic (the provider disallows direct
 * grant, so a token is only obtainable from a real authenticated run — same
 * technique as slice.spec.ts). Caller closes the returned context.
 */
export async function loginAndCaptureToken(
  browser: Browser,
  user: string,
  pass: string,
): Promise<{ context: BrowserContext; page: Page; token: string }> {
  const context = await browser.newContext();
  const page = await context.newPage();
  let token = "";
  page.on("request", (req) => {
    const auth = req.headers()["authorization"];
    if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
      token = auth.slice("Bearer ".length);
    }
  });
  await submitIdpCredentials(page, user, pass);
  await page.waitForURL(/app\.beekeepingit\.local/, { timeout: 60_000 });
  await expect.poll(() => token, { timeout: 30_000 }).not.toBe("");
  return { context, page, token };
}
