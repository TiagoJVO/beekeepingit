import { test, expect } from "@playwright/test";
import {
  apiJson,
  countMessagesTo,
  expectLoginCompleted,
  invitationStatus,
  loginAndCaptureToken,
  MAILPIT_URL,
  pollForVerificationLink,
  submitIdpCredentials,
} from "./helpers";

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
 *   7. SELF-SERVICE EMAIL CHANGE IS DISABLED: a verified user's attempt to
 *      change their own email through Authentik's real user-settings flow is
 *      rejected ("Not allowed to change email address." —
 *      Tenant.default_user_change_email defaults to false on the pinned
 *      2026.5.4), which closes the #170-shape attack (re-pointing one's own
 *      verified address at a victim's pending invitation) one level EARLIER
 *      than any reset-on-change policy could. This test is the live pin on
 *      that control: the setting is not blueprint-manageable (the Tenant
 *      model is InternallyManagedMixin-excluded — see the blueprint's
 *      comment), so a version bump that flips the default turns this red
 *      instead of silently opening the path.
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

// (The Mailpit/link/invitation/token helpers this spec introduced moved to
// ./helpers.ts when registration.spec.ts (#366) grew the same needs.)
const AUTH_ORIGIN = process.env.E2E_AUTH_ORIGIN ?? "https://auth.beekeepingit.local:8443";
const UNVERIFIED_USER =
  process.env.E2E_UNVERIFIED_USER ?? "unverified.beekeeper@beekeepingit.local";
const UNVERIFIED_PASS = process.env.E2E_UNVERIFIED_PASS ?? "dev-password123";
// The seeded org admin (devseed: admin membership in the dev org) — used to
// create the invitation the accept-on-login assertions revolve around. Same
// defaults as slice.spec.ts's login.
const ADMIN_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const ADMIN_PASS = process.env.E2E_PASS ?? "dev-password123";
// The address the (rejected) email-change attempt targets. Never a real
// inbox — dev/CI mail all lands in the Mailpit sink.
const CHANGED_EMAIL = "changed.beekeeper@beekeepingit.local";

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

  test("self-service email change via the user-settings flow is rejected; the verified claim survives untouched", async ({
    page,
    request,
    browser,
  }) => {
    // Two full OIDC logins plus the settings-flow executor calls.
    test.setTimeout(360_000);

    // ── Login as the (now verified, from the test above) seed user ─────────
    await submitIdpCredentials(page, UNVERIFIED_USER, UNVERIFIED_PASS);
    await expectLoginCompleted(page, UNVERIFIED_USER);

    // ── Attempt an email change through the REAL user-settings flow ────────
    // Drive Authentik's own flow executor for default-user-settings-flow via
    // its JSON API from the authenticated browser session — the exact executor
    // path the /if/user/#/settings UI posts to (same session cookie + CSRF
    // header the SPA would send), minus the brittle shadow-DOM driving.
    //
    // Expected: REJECTED. Tenant.default_user_change_email defaults to false
    // on the pinned 2026.5.4, so the flow's own validation policy
    // (default-user-settings-authorization) refuses any email change — the
    // control that closes the #170-shape attack (see the blueprint's
    // "Self-service email change is DISABLED" section for why this cannot be
    // pinned in the blueprint itself; this assertion IS the pin). To prove
    // the rejection is specifically about the email — not a broken flow — a
    // second submit with the email left unchanged must complete.
    await page.goto(`${AUTH_ORIGIN}/if/user/`, { waitUntil: "domcontentloaded" });
    const flow = await page.evaluate(
      async ({ newEmail }) => {
        type Challenge = {
          component?: string;
          fields?: Array<{ field_key: string; initial_value?: string }>;
          response_errors?: Record<string, Array<{ string: string; code: string }>>;
        };
        const executor = "/api/v3/flows/executor/default-user-settings-flow/?query=";
        const start = await fetch(executor, { headers: { Accept: "application/json" } });
        const challenge = (await start.json()) as Challenge;
        if (challenge.component !== "ak-stage-prompt") {
          return {
            step: "start",
            changeAttempt: challenge,
            unchangedSubmit: null as Challenge | null,
          };
        }
        // Echo every prompt field's server-provided initial value (username,
        // name, locale) — the same submission the settings UI would make.
        const fromFields = (): Record<string, unknown> => {
          const body: Record<string, unknown> = { component: "ak-stage-prompt" };
          for (const field of challenge.fields ?? []) {
            body[field.field_key] = field.initial_value ?? "";
          }
          return body;
        };
        const csrf = () => document.cookie.match(/authentik_csrf=([^;]+)/)?.[1] ?? "";
        const submit = async (body: Record<string, unknown>): Promise<Challenge> => {
          const post = await fetch(executor, {
            method: "POST",
            headers: {
              Accept: "application/json",
              "Content-Type": "application/json",
              "X-authentik-CSRF": csrf(),
            },
            body: JSON.stringify(body),
          });
          return (await post.json()) as Challenge;
        };

        // 1) The email-change attempt — must be rejected.
        const changeAttempt = await submit({ ...fromFields(), email: newEmail });
        // 2) The same submit with the email untouched — must complete, so the
        //    rejection above is attributable to the email change alone.
        const unchangedSubmit: Challenge | null = await submit(fromFields());
        return { step: "submit", changeAttempt, unchangedSubmit };
      },
      { newEmail: CHANGED_EMAIL },
    );

    // The change attempt is re-served the prompt with the exact policy error.
    expect(
      flow.changeAttempt.component,
      `email-change attempt ended on ${JSON.stringify(flow)}`,
    ).toBe("ak-stage-prompt");
    const errors = flow.changeAttempt.response_errors?.["non_field_errors"] ?? [];
    expect(
      errors.some((e) => /not allowed to change email/i.test(e.string)),
      `expected the email-change rejection error, got ${JSON.stringify(flow.changeAttempt)}`,
    ).toBe(true);
    // The email-unchanged submit sails through — the flow itself works.
    expect(
      flow.unchangedSubmit?.component,
      `email-unchanged submit ended on ${JSON.stringify(flow.unchangedSubmit)}`,
    ).toBe("xak-flow-redirect");

    // No verification email was triggered for the attempted address.
    expect(await countMessagesTo(request, CHANGED_EMAIL)).toBe(0);

    // ── A fresh login is untouched: still verified, no re-verification ─────
    const before = await countMessagesTo(request, UNVERIFIED_USER);
    const secondContext = await browser.newContext();
    const secondPage = await secondContext.newPage();
    try {
      await submitIdpCredentials(secondPage, UNVERIFIED_USER, UNVERIFIED_PASS);
      // Straight through — no email stage, claim still the ORIGINAL address,
      // still verified.
      await expectLoginCompleted(secondPage, UNVERIFIED_USER);
      expect(await countMessagesTo(request, UNVERIFIED_USER)).toBe(before);
    } finally {
      await secondContext.close();
    }
  });
});
