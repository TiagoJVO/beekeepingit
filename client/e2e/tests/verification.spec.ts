import { test, expect, Page, Browser, BrowserContext, APIRequestContext } from "@playwright/test";
import { readIdTokenClaims, submitIdpCredentials } from "./helpers";

/**
 * Email-verification flow e2e (#361, NFR-SEC-1, NFR-TST-1).
 *
 * Proves, against the live stack, that:
 *   1. an UNVERIFIED user's login is held at the IdP's email stage (never
 *      reaches the app authenticated),
 *   2. a verification email is actually delivered over the configured SMTP
 *      path (captured by the Mailpit sink),
 *   3. opening the emailed one-time link completes the flow, marks the address
 *      verified, and the login finishes,
 *   4. the token the app then holds carries the REAL `email_verified: true` —
 *      the claim the invitation accept-on-login gate (#170) trusts,
 *   5. the invitation accept-on-login path (FR-ONB-3) integrates with that
 *      claim end to end: an org admin's pending invitation for this address is
 *      NOT claimable while the user is held unverified, and IS auto-claimed by
 *      the first authenticated `GET /v1/organizations/me` once verified,
 *   6. the verified state PERSISTS: a second, fresh login goes straight
 *      through with no new verification email,
 *   7. changing the email through Authentik's own user-settings flow RESETS
 *      verification: the next login is re-gated on a fresh emailed link sent
 *      to the NEW address (the #170-shape guard one layer down — see the
 *      blueprint's email-change policy).
 *
 * Requires a fresh, blueprint-seeded stack (the unverified seed user must
 * still be unverified) plus the Mailpit API reachable from the runner —
 * helm-e2e.yml port-forwards it and sets E2E_MAILPIT_URL. Skipped when that
 * env is absent (e.g. a local run against a long-lived cluster where the user
 * verified in an earlier run).
 *
 * The tests are order-dependent (the file runs on one worker, in declaration
 * order — fullyParallel is off): the email-change test relies on the first
 * test having verified the seed user.
 */

const MAILPIT_URL = process.env.E2E_MAILPIT_URL ?? "";
const AUTH_ORIGIN = process.env.E2E_AUTH_ORIGIN ?? "https://auth.beekeepingit.local:8443";
const API_URL = process.env.E2E_API_URL ?? "";
const UNVERIFIED_USER =
  process.env.E2E_UNVERIFIED_USER ?? "unverified.beekeeper@beekeepingit.local";
const UNVERIFIED_PASS = process.env.E2E_UNVERIFIED_PASS ?? "dev-password123";
// The seeded org admin (devseed: admin membership in the dev org) — used to
// create the invitation the accept-on-login assertions revolve around. Same
// defaults as slice.spec.ts's login.
const ADMIN_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const ADMIN_PASS = process.env.E2E_PASS ?? "dev-password123";
// The address the email-change test moves the seed user to. Never a real
// inbox — dev/CI mail all lands in the Mailpit sink.
const CHANGED_EMAIL = "changed.beekeeper@beekeepingit.local";

// Extracts the one-time verification link for `recipient` from the Mailpit
// API. The message body is the built-in account-confirmation template whose
// text part carries the bare flow URL on its own line. (The body renders in
// English regardless of user locale on the pinned Authentik 2026.5.4 — see
// the blueprint's i18n note — so no locale-sensitive matching is needed.)
async function pollForVerificationLink(
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

async function countMessagesTo(request: APIRequestContext, recipient: string): Promise<number> {
  const list = await request.get(
    `${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:${recipient}`)}`,
  );
  const body = (await list.json()) as { messages?: unknown[] };
  return body.messages?.length ?? 0;
}

// A login that completed lands the user back on the app origin — the
// onboarding gate then routes by profile/org state (/profile for a fresh
// user, /apiaries once the invitation below has joined them to the org).
// Anything still on the auth host means the flow didn't finish.
async function expectLoginCompleted(page: Page, expectedEmail: string) {
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
async function apiJson(
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
async function invitationStatus(
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
async function loginAndCaptureToken(
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

test.describe("email verification at login (#361)", () => {
  test.skip(
    !MAILPIT_URL,
    "E2E_MAILPIT_URL not set — needs a fresh blueprint-seeded stack + the Mailpit sink port-forwarded (helm-e2e.yml)",
  );

  test("unverified login is gated on the emailed link; a pending invitation is claimed only once verified", async ({
    page,
    request,
    browser,
  }) => {
    // Three full OIDC logins (admin + the gated one + the persistence check)
    // plus two Mailpit polls — the default 240s budget is too tight on a cold
    // stack where the first login alone may burn ~2 min of gateway warmup.
    test.setTimeout(420_000);

    // ── As the seeded org admin, invite the unverified user's address ──────
    // (FR-ONB-3 / #170: the accept-on-login gate this spec integrates with.)
    const admin = await loginAndCaptureToken(browser, ADMIN_USER, ADMIN_PASS);
    try {
      const me = await apiJson(admin.page, admin.token, "GET", "/organizations/me");
      expect(me.status).toBe(200);
      const orgId = me.json.id as string;

      const created = await apiJson(
        admin.page,
        admin.token,
        "POST",
        `/organizations/${orgId}/invitations`,
        {
          email: UNVERIFIED_USER,
          role: "user",
        },
      );
      // 201 on the fresh stack this spec requires; 409 tolerated so a CI
      // retry (invitation left over from the first attempt) fails on the
      // real assertions below rather than here.
      expect([201, 409]).toContain(created.status);

      // Capture the unverified user's own bearer once their login completes,
      // for the /organizations/me assertion at the end.
      let userToken = "";
      page.on("request", (req) => {
        const auth = req.headers()["authorization"];
        if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
          userToken = auth.slice("Bearer ".length);
        }
      });

      // ── Login as the unverified seed user: held at the email stage ────────
      await submitIdpCredentials(page, UNVERIFIED_USER, UNVERIFIED_PASS);

      // The authentication flow's email stage now blocks the login: we must
      // still be on the auth host (NOT back on the app with a session). Assert
      // the host rather than any stage copy so the check is locale/markup
      // agnostic.
      await expect(page).toHaveURL(/auth\.beekeepingit\.local/, { timeout: 30_000 });

      // While held, the invitation is untouchable: the unverified user cannot
      // complete a login, so nothing can present a verified claim for this
      // address yet — the admin still sees it pending.
      expect(await invitationStatus(admin.page, admin.token, orgId, UNVERIFIED_USER)).toBe(
        "pending",
      );

      // ── The verification email arrives through the real SMTP path ─────────
      const link = await pollForVerificationLink(request, UNVERIFIED_USER);
      expect(link).toContain("auth.beekeepingit.local");

      // Still held at the IdP the whole time the email was in flight — the flow
      // genuinely did not complete without the link (the URL check above alone
      // would pass trivially right after submit).
      expect(page.url()).toMatch(/auth\.beekeepingit\.local/);

      // ── Open the one-time link: the flow resumes and completes ────────────
      // Authentik prepends a consent step to emailed links (an email-scanner
      // guard: "Continue to confirm this email address") — click through it when
      // it appears. Loose label matching, same provider-agnostic stance as the
      // login helpers.
      await page.goto(link);
      const continueButton = page.getByRole("button", { name: /continue|confirm|authorize|next/i });
      if (
        await continueButton
          .first()
          .waitFor({ state: "visible", timeout: 15_000 })
          .then(() => true)
          .catch(() => false)
      ) {
        await continueButton.first().click();
      }

      // The flow finishes login and returns to the app; the persisted id_token
      // must now carry the REAL verified state.
      await expectLoginCompleted(page, UNVERIFIED_USER);

      // ── The invitation is claimed by the first verified org lookup ────────
      // The app's own router org-gate calls GET /v1/organizations/me on boot;
      // with the claim now genuinely true, that call auto-accepts the pending
      // invitation (FR-ONB-3 AC: joined to the inviting org rather than
      // prompted to create one). Call it explicitly with the user's own token
      // too, so the assertion doesn't depend on the app's internal timing —
      // the accept is idempotent.
      await expect.poll(() => userToken, { timeout: 30_000 }).not.toBe("");
      const mine = await apiJson(page, userToken, "GET", "/organizations/me");
      expect(mine.status).toBe(200);
      expect(mine.json.id).toBe(orgId);
      expect(mine.json.role).toBe("user");
      await expect
        .poll(() => invitationStatus(admin.page, admin.token, orgId, UNVERIFIED_USER), {
          timeout: 30_000,
        })
        .toBe("accepted");

      // ── Verified state persists: a fresh login sails through ──────────────
      const before = await countMessagesTo(request, UNVERIFIED_USER);
      const secondContext = await browser.newContext();
      const secondPage = await secondContext.newPage();
      try {
        await submitIdpCredentials(secondPage, UNVERIFIED_USER, UNVERIFIED_PASS);
        await expectLoginCompleted(secondPage, UNVERIFIED_USER);
        // No new verification email was sent for the already-verified address.
        expect(await countMessagesTo(request, UNVERIFIED_USER)).toBe(before);
      } finally {
        await secondContext.close();
      }
    } finally {
      await admin.context.close();
    }
  });

  test("changing the email via the user-settings flow resets verification; the next login re-verifies the NEW address", async ({
    page,
    request,
    browser,
  }) => {
    // Two full OIDC logins plus a Mailpit poll and the settings-flow call.
    test.setTimeout(360_000);

    // ── Login as the (now verified, from the test above) seed user ─────────
    await submitIdpCredentials(page, UNVERIFIED_USER, UNVERIFIED_PASS);
    await expectLoginCompleted(page, UNVERIFIED_USER);

    // ── Change the email through the REAL user-settings flow ───────────────
    // Drive Authentik's own flow executor for default-user-settings-flow via
    // its JSON API from the authenticated browser session — the exact executor
    // path the /if/user/#/settings UI posts to (same session cookie + CSRF
    // header the SPA would send), minus the brittle shadow-DOM driving. This
    // exercises the blueprint's redeclared user_write binding for real: if its
    // identifiers ever drift from upstream's (a silently upserted duplicate
    // binding), the reset below stops firing and this test goes red.
    await page.goto(`${AUTH_ORIGIN}/if/user/`, { waitUntil: "domcontentloaded" });
    const flow = await page.evaluate(
      async ({ newEmail }) => {
        const executor = "/api/v3/flows/executor/default-user-settings-flow/?query=";
        const start = await fetch(executor, { headers: { Accept: "application/json" } });
        const challenge = (await start.json()) as {
          component?: string;
          fields?: Array<{ field_key: string; initial_value?: string }>;
        };
        if (challenge.component !== "ak-stage-prompt") {
          return { step: "start", result: challenge };
        }
        // Echo every prompt field's server-provided initial value (username,
        // name, locale) and override only the email — the same submission the
        // settings UI would make.
        const body: Record<string, unknown> = { component: "ak-stage-prompt" };
        for (const field of challenge.fields ?? []) {
          body[field.field_key] = field.initial_value ?? "";
        }
        body["email"] = newEmail;
        const csrf = document.cookie.match(/authentik_csrf=([^;]+)/)?.[1] ?? "";
        const post = await fetch(executor, {
          method: "POST",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            "X-authentik-CSRF": csrf,
          },
          body: JSON.stringify(body),
        });
        return { step: "submit", result: (await post.json()) as { component?: string } };
      },
      { newEmail: CHANGED_EMAIL },
    );
    // A completed flow answers with the redirect pseudo-stage; anything else
    // (validation errors, access denied, a re-served prompt) is surfaced whole.
    expect(flow.result.component, `user-settings flow ended on ${JSON.stringify(flow)}`).toBe(
      "xak-flow-redirect",
    );

    // Baseline before the re-gated login: nothing has ever been mailed to the
    // new address (fresh stack) — so an arrival below is attributable to the
    // login re-triggering the verification stage.
    const baseline = await countMessagesTo(request, CHANGED_EMAIL);

    // ── A fresh login is re-gated: the email change reset verification ─────
    const secondContext = await browser.newContext();
    const secondPage = await secondContext.newPage();
    try {
      await submitIdpCredentials(secondPage, UNVERIFIED_USER, UNVERIFIED_PASS);
      await expect(secondPage).toHaveURL(/auth\.beekeepingit\.local/, { timeout: 30_000 });

      // The verification email goes to the NEW address — the reset really
      // re-targeted the changed email, not a stale copy of the old one.
      const link = await pollForVerificationLink(request, CHANGED_EMAIL);
      expect(link).toContain("auth.beekeepingit.local");
      expect(await countMessagesTo(request, CHANGED_EMAIL)).toBeGreaterThan(baseline);

      // Still held until the link is used.
      expect(secondPage.url()).toMatch(/auth\.beekeepingit\.local/);

      // ── Completing the link re-verifies; the claim carries the NEW email ──
      await secondPage.goto(link);
      const continueButton = secondPage.getByRole("button", {
        name: /continue|confirm|authorize|next/i,
      });
      if (
        await continueButton
          .first()
          .waitFor({ state: "visible", timeout: 15_000 })
          .then(() => true)
          .catch(() => false)
      ) {
        await continueButton.first().click();
      }
      await expectLoginCompleted(secondPage, CHANGED_EMAIL);
    } finally {
      await secondContext.close();
    }
  });
});
