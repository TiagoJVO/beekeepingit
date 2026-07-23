import { test, expect, Page, APIRequestContext } from "@playwright/test";
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
 *   5. the verified state PERSISTS: a second, fresh login goes straight
 *      through with no new verification email.
 *
 * Requires a fresh, blueprint-seeded stack (the unverified seed user must
 * still be unverified) plus the Mailpit API reachable from the runner —
 * helm-e2e.yml port-forwards it and sets E2E_MAILPIT_URL. Skipped when that
 * env is absent (e.g. a local run against a long-lived cluster where the user
 * verified in an earlier run).
 */

const MAILPIT_URL = process.env.E2E_MAILPIT_URL ?? "";
const UNVERIFIED_USER =
  process.env.E2E_UNVERIFIED_USER ?? "unverified.beekeeper@beekeepingit.local";
const UNVERIFIED_PASS = process.env.E2E_UNVERIFIED_PASS ?? "dev-password123";

// Extracts the one-time verification link for `recipient` from the Mailpit
// API. The message body is the (localized) built-in account-confirmation
// template whose text part carries the bare flow URL on its own line.
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

// A login that completed lands the (brand-new, profile-less) user back on the
// app origin — the onboarding gate routes to /profile. Anything still on the
// auth host means the flow didn't finish.
async function expectLoginCompleted(page: Page) {
  await page.waitForURL(/app\.beekeepingit\.local|\/profile/, { timeout: 60_000 });
  const claims = await readIdTokenClaims(page);
  expect(claims.email).toBe(UNVERIFIED_USER);
  expect(claims.email_verified).toBe(true);
}

test.describe("email verification at login (#361)", () => {
  test.skip(
    !MAILPIT_URL,
    "E2E_MAILPIT_URL not set — needs a fresh blueprint-seeded stack + the Mailpit sink port-forwarded (helm-e2e.yml)",
  );

  test("unverified login is gated on the emailed link; completing it marks the address verified", async ({
    page,
    request,
    browser,
  }) => {
    // ── Login as the unverified seed user: held at the email stage ────────
    await submitIdpCredentials(page, UNVERIFIED_USER, UNVERIFIED_PASS);

    // The authentication flow's email stage now blocks the login: we must
    // still be on the auth host (NOT back on the app with a session). Assert
    // the host rather than any stage copy so the check is locale/markup
    // agnostic.
    await expect(page).toHaveURL(/auth\.beekeepingit\.local/, { timeout: 30_000 });

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
    await expectLoginCompleted(page);

    // ── Verified state persists: a fresh login sails through ──────────────
    const before = await countMessagesTo(request, UNVERIFIED_USER);
    const secondContext = await browser.newContext();
    const secondPage = await secondContext.newPage();
    try {
      await submitIdpCredentials(secondPage, UNVERIFIED_USER, UNVERIFIED_PASS);
      await expectLoginCompleted(secondPage);
      // No new verification email was sent for the already-verified address.
      expect(await countMessagesTo(request, UNVERIFIED_USER)).toBe(before);
    } finally {
      await secondContext.close();
    }
  });
});
