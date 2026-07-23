import { test, expect, Page } from "@playwright/test";
import {
  apiJson,
  countMessagesTo,
  enableSemantics,
  expectLoginCompleted,
  gotoAppRoot,
  invitationStatus,
  loginAndCaptureToken,
  MAILPIT_URL,
  pollForVerificationLink,
  readIdTokenClaims,
  submitButton,
  submitIdpCredentials,
} from "./helpers";

/**
 * Self-service registration e2e (#366, FR-ONB-1/2/3, FR-AU-1, NFR-SEC-1,
 * NFR-TST-1). Proves, against the live stack, that:
 *
 *   1. a user with NO invitation can register with an email address and
 *      password through the IdP's enrollment flow, reached from the app's own
 *      sign-in redirect via the login page's "Sign up." link (#366 AC 1),
 *   2. the registration is HELD unverified on the emailed one-time link — no
 *      session, no token, and a pending invitation for the address stays
 *      unclaimable the whole time (AC 2/3),
 *   3. an abandoned registration self-heals at login: a plain login attempt
 *      with the new credentials is held at the authentication flow's own
 *      email stage (the #361 gate) and re-sends a fresh link — it never
 *      yields a session while unverified,
 *   4. opening the emailed link completes enrollment end to end: the
 *      verified-stamp lands (`email_verified: true` in the real id_token),
 *      the preserved ?next returns the browser into the pending OAuth
 *      authorize, and the app's ordinary first-sign-in onboarding takes over
 *      (FR-ONB-1 profile → invitation auto-claim / org creation, AC 4),
 *   5. onboarding to a NEW organization works for a registered user, and the
 *      creator lands as `admin` (FR-ONB-2, D-3),
 *   6. registering with an EXISTING account's email address grants nothing:
 *      it creates a distinct, unlinked account (different `sub`) with no
 *      memberships, and the original account is untouched (AC 2's
 *      no-claim/no-merge reduction — account linking itself is #364).
 *
 * Same opt-in switch as verification.spec.ts: requires the Mailpit sink
 * (E2E_MAILPIT_URL, port-forwarded by helm-e2e.yml) and a blueprint-seeded
 * stack. All accounts are created BY this spec with a per-run unique suffix —
 * it deliberately never touches the seed users (slice.spec.ts and
 * verification.spec.ts, which run after this file alphabetically, depend on
 * their seeded state).
 *
 * Test 3 is fully self-contained (registers its own "victim") so a CI retry
 * in a fresh worker — where this module's state from earlier tests is gone —
 * still tests what it claims to test.
 */

const ADMIN_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const ADMIN_PASS = process.env.E2E_PASS ?? "dev-password123";

// Per-worker unique suffix: usernames/emails must not collide with a previous
// attempt's accounts (usernames are unique at the IdP). A failed test retries
// in a fresh worker process, which re-evaluates this to a new value.
const RUN = `${Date.now()}`;
// >= 12 chars — the blueprint's enrollment password policy (length-only
// static rule). Dev/CI-grade, same posture as the seeded dev-password123.
const PASSWORD = "reg-password-123456";
const INVITEE_USERNAME = `reg.invitee.${RUN}`;
const INVITEE_EMAIL = `reg.invitee.${RUN}@beekeepingit.local`;
const FOUNDER_USERNAME = `reg.founder.${RUN}`;
const FOUNDER_EMAIL = `reg.founder.${RUN}@beekeepingit.local`;
const VICTIM_USERNAME = `reg.victim.${RUN}`;
const VICTIM_EMAIL = `reg.victim.${RUN}@beekeepingit.local`;
const SQUATTER_USERNAME = `reg.squatter.${RUN}`;

// The dev/CI seed admin's pinned sub (blueprint `upn`) — registered users'
// subs must never collide with it.
const SEED_SUB = "11111111-1111-4111-8111-111111111111";
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * From the app's login screen, start the OIDC redirect and follow the IdP
 * login page's enrollment link ("Need an account? Sign up." — rendered by the
 * identification stage because the blueprint sets its enrollment_flow). Going
 * through the app first matters: it puts the OAuth authorize request into the
 * flow's ?next, which the enrollment flow preserves all the way through the
 * emailed link, so completing registration lands back IN THE APP (AC 4).
 */
async function startSignUp(page: Page) {
  await gotoAppRoot(page);
  await enableSemantics(page);
  const appSignIn = page.getByRole("button", { name: /sign in/i });
  await appSignIn.waitFor({ state: "visible", timeout: 60_000 });
  await appSignIn.click();

  const signUp = page.getByRole("link", { name: /sign up/i });
  await signUp.waitFor({ state: "visible", timeout: 30_000 });
  await signUp.click();
}

/**
 * Fills and submits the enrollment prompt (username/email/password/repeat).
 * Fields are located by the placeholders the blueprint declares — stable,
 * and unlike labels they carry no required-marker decoration.
 */
async function submitEnrollmentForm(page: Page, username: string, email: string) {
  const usernameField = page.getByPlaceholder("Username", { exact: true });
  await usernameField.waitFor({ state: "visible", timeout: 30_000 });
  await usernameField.fill(username);
  await page.getByPlaceholder("Email", { exact: true }).fill(email);
  await page.getByPlaceholder("Password", { exact: true }).fill(PASSWORD);
  await page.getByPlaceholder("Password (repeat)", { exact: true }).fill(PASSWORD);
  await submitButton(page).first().click();
}

/**
 * Asserts the enrollment was accepted and is now HELD at the email stage:
 * still on the auth host (no session, not back in the app) AND past the
 * prompt (its fields are gone — a validation error would re-serve them, which
 * would make a bare host check pass trivially). The actual send is proven by
 * the caller's Mailpit poll.
 */
async function expectHeldAtEmailStage(page: Page) {
  await expect(page).toHaveURL(/auth\.beekeepingit\.local/, { timeout: 30_000 });
  await expect(page.getByPlaceholder("Username", { exact: true })).toHaveCount(0, {
    timeout: 30_000,
  });
}

/**
 * Opens the emailed one-time link and expects the whole tail of the journey
 * to complete: consent interstitial (Authentik's email-scanner guard, same
 * handling as verification.spec.ts) → verified-stamp → user_login → preserved
 * ?next → OAuth authorize → back on the app origin with a REAL
 * `email_verified: true` id_token.
 */
async function completeViaEmailedLink(page: Page, link: string, email: string) {
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
  await expectLoginCompleted(page, email);
}

// Flutter-web text entry with the same dropped-keystroke workaround
// slice.spec.ts uses (clear first, then type with a small delay).
async function typeInto(page: Page, field: ReturnType<Page["getByLabel"]>, value: string) {
  await field.first().waitFor({ state: "visible", timeout: 30_000 });
  await field.first().click();
  await page.keyboard.press("Control+A");
  await page.keyboard.press("Delete");
  await page.keyboard.press("Backspace");
  await page.keyboard.type(value, { delay: 50 });
}

/**
 * Completes the FR-ONB-1 profile step (the app routes a fresh, verified user
 * here on first sign-in). The email field may arrive prefilled from the
 * first-seen profile row — overwrite it either way so the state is definite.
 */
async function completeProfile(page: Page, name: string, email: string) {
  await page.waitForURL(/\/profile/, { timeout: 60_000 });
  await enableSemantics(page);
  await typeInto(page, page.getByLabel("Name", { exact: true }), name);
  await typeInto(page, page.getByLabel("Email", { exact: true }), email);
  await page.getByText("Save profile", { exact: true }).click();
}

test.describe("self-service registration (#366)", () => {
  test.skip(
    !MAILPIT_URL,
    "E2E_MAILPIT_URL not set — needs a fresh blueprint-seeded stack + the Mailpit sink port-forwarded (helm-e2e.yml)",
  );

  test("register without an invitation → held unverified (pending invitation unclaimable) → verify → onboarding joins the inviting org", async ({
    page,
    request,
    browser,
  }) => {
    // One admin login + the registration + a held login attempt + the link
    // completion + onboarding, plus two Mailpit polls — budget like
    // verification.spec.ts's long test.
    test.setTimeout(480_000);

    // ── As the seeded org admin, invite the address about to register ─────
    // (FR-ONB-3/#170: the accept-on-login gate this spec integrates with —
    // the invitation exists BEFORE the account does.)
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
        { email: INVITEE_EMAIL, role: "user" },
      );
      expect(created.status).toBe(201);

      // Capture the registrant's own bearer once their login eventually
      // completes, for the /organizations/me assertions at the end.
      let userToken = "";
      page.on("request", (req) => {
        const auth = req.headers()["authorization"];
        if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
          userToken = auth.slice("Bearer ".length);
        }
      });

      // ── Register through the login page's Sign up link (AC 1) ─────────────
      await startSignUp(page);
      await submitEnrollmentForm(page, INVITEE_USERNAME, INVITEE_EMAIL);
      await expectHeldAtEmailStage(page);

      // The enrollment verification email arrives through the real SMTP path.
      // Captured BEFORE the login attempt below sends a second one — the
      // helper always returns the newest message for the address.
      const enrollmentLink = await pollForVerificationLink(request, INVITEE_EMAIL);
      expect(enrollmentLink).toContain("auth.beekeepingit.local");
      const emailsAfterEnrollment = await countMessagesTo(request, INVITEE_EMAIL);

      // While held, the invitation is untouchable (AC 3): no login can
      // complete for this address, so nothing can present a verified claim —
      // the admin still sees it pending.
      expect(await invitationStatus(admin.page, admin.token, orgId, INVITEE_EMAIL)).toBe("pending");

      // ── An unverified registration cannot log in either (AC 2/3) ──────────
      // A plain login attempt with the just-registered credentials is held at
      // the AUTHENTICATION flow's email stage (#361's gate — the recovery
      // path for an abandoned registration) and re-sends a fresh link; it
      // never reaches the app.
      const attempt = await browser.newContext();
      try {
        const attemptPage = await attempt.newPage();
        await submitIdpCredentials(attemptPage, INVITEE_USERNAME, PASSWORD);
        await expect(attemptPage).toHaveURL(/auth\.beekeepingit\.local/, { timeout: 30_000 });
        // The re-sent link is the self-heal proof (a fresh email for the
        // address, on top of the enrollment one).
        await expect
          .poll(() => countMessagesTo(request, INVITEE_EMAIL), { timeout: 60_000 })
          .toBeGreaterThan(emailsAfterEnrollment);
      } finally {
        await attempt.close();
      }

      // Still pending — the held login attempt changed nothing.
      expect(await invitationStatus(admin.page, admin.token, orgId, INVITEE_EMAIL)).toBe("pending");

      // ── Open the enrollment link: verified, logged in, back in the app ────
      await completeViaEmailedLink(page, enrollmentLink, INVITEE_EMAIL);
      const claims = await readIdTokenClaims(page);
      // The enrollment flow assigned a UUID `sub` (upn policy — the
      // oidc-integration.md §4 forward-requirement), distinct from the seed's.
      expect(claims.sub).toMatch(UUID_V4);
      expect(claims.sub).not.toBe(SEED_SUB);

      // ── Onboarding proceeds as any first sign-in (AC 4, FR-ONB-1/3) ───────
      // Profile first; the org gate then auto-claims the (now claimable)
      // pending invitation on its GET /organizations/me, so the router lands
      // on /apiaries — joined, not prompted to create an org.
      await completeProfile(page, "Reg Invitee", INVITEE_EMAIL);
      await page.waitForURL(/\/apiaries/, { timeout: 60_000 });

      await expect.poll(() => userToken, { timeout: 30_000 }).not.toBe("");
      const mine = await apiJson(page, userToken, "GET", "/organizations/me");
      expect(mine.status).toBe(200);
      expect(mine.json.id).toBe(orgId);
      expect(mine.json.role).toBe("user");
      await expect
        .poll(() => invitationStatus(admin.page, admin.token, orgId, INVITEE_EMAIL), {
          timeout: 30_000,
        })
        .toBe("accepted");
    } finally {
      await admin.context.close();
    }
  });

  test("register → verify → full onboarding to a new organization; the creator is admin (D-3)", async ({
    page,
    request,
  }) => {
    test.setTimeout(420_000);

    let userToken = "";
    page.on("request", (req) => {
      const auth = req.headers()["authorization"];
      if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
        userToken = auth.slice("Bearer ".length);
      }
    });

    // ── Register + verify (no invitation exists for this address) ─────────
    await startSignUp(page);
    await submitEnrollmentForm(page, FOUNDER_USERNAME, FOUNDER_EMAIL);
    await expectHeldAtEmailStage(page);
    const link = await pollForVerificationLink(request, FOUNDER_EMAIL);
    await completeViaEmailedLink(page, link, FOUNDER_EMAIL);
    expect((await readIdTokenClaims(page)).sub).toMatch(UUID_V4);

    // ── FR-ONB-1 profile, then FR-ONB-2 org creation ──────────────────────
    // With no invitation to claim, the org gate routes to /organization/new.
    await completeProfile(page, "Reg Founder", FOUNDER_EMAIL);
    await page.waitForURL(/\/organization\/new/, { timeout: 60_000 });
    await enableSemantics(page);
    await typeInto(page, page.getByLabel("Organization name", { exact: true }), `Reg Org ${RUN}`);
    await page.getByText("Create organization", { exact: true }).click();
    await page.waitForURL(/\/apiaries/, { timeout: 60_000 });
    await enableSemantics(page);
    await expect(page.getByRole("heading", { name: "Apiaries" })).toBeVisible({
      timeout: 30_000,
    });

    // D-3: the creator became the org's admin.
    await expect.poll(() => userToken, { timeout: 30_000 }).not.toBe("");
    const mine = await apiJson(page, userToken, "GET", "/organizations/me");
    expect(mine.status).toBe(200);
    expect(mine.json.role).toBe("admin");
  });

  test("registering with an existing account's email creates a distinct account and grants nothing (AC 2)", async ({
    page,
    request,
    browser,
  }) => {
    test.setTimeout(480_000);

    // ── Self-contained victim: register + verify a fresh account ──────────
    // (Not one of the earlier tests' users, so a CI retry in a fresh worker —
    // where this module's state is re-created — still holds.)
    await startSignUp(page);
    await submitEnrollmentForm(page, VICTIM_USERNAME, VICTIM_EMAIL);
    await expectHeldAtEmailStage(page);
    const victimLink = await pollForVerificationLink(request, VICTIM_EMAIL);
    await completeViaEmailedLink(page, victimLink, VICTIM_EMAIL);
    const victimSub = (await readIdTokenClaims(page)).sub as string;
    expect(victimSub).toMatch(UUID_V4);

    // ── The squatter registers with the VICTIM's email ────────────────────
    // Allowed (upstream default — no uniqueness policy, so no new
    // account-existence signal either), but held unverified like any other
    // registration: without inbox control this account can never log in.
    const squatter = await browser.newContext();
    try {
      const squatterPage = await squatter.newPage();
      let squatterToken = "";
      squatterPage.on("request", (req) => {
        const auth = req.headers()["authorization"];
        if (auth?.startsWith("Bearer ") && req.url().includes("/v1/")) {
          squatterToken = auth.slice("Bearer ".length);
        }
      });
      await startSignUp(squatterPage);
      await submitEnrollmentForm(squatterPage, SQUATTER_USERNAME, VICTIM_EMAIL);
      await expectHeldAtEmailStage(squatterPage);

      // Complete the squatter's verification via the sink — in CI, Mailpit
      // makes us the inbox owner for every address, so this deliberately
      // simulates the WORST case (the mail somehow reached the attacker).
      // Even then: a distinct, unlinked account — never the victim's.
      const squatterLink = await pollForVerificationLink(request, VICTIM_EMAIL);
      await completeViaEmailedLink(squatterPage, squatterLink, VICTIM_EMAIL);
      const squatterClaims = await readIdTokenClaims(squatterPage);
      expect(squatterClaims.sub).toMatch(UUID_V4);
      expect(squatterClaims.sub).not.toBe(victimSub);

      // Nothing inherited: the squatter is a fresh, org-less user routed to
      // first-sign-in onboarding, and the API agrees (404 — no membership,
      // no claimable invitation).
      await squatterPage.waitForURL(/\/profile/, { timeout: 60_000 });
      await expect.poll(() => squatterToken, { timeout: 30_000 }).not.toBe("");
      const squatterOrg = await apiJson(squatterPage, squatterToken, "GET", "/organizations/me");
      expect(squatterOrg.status).toBe(404);
    } finally {
      await squatter.close();
    }

    // ── The victim's account is untouched ─────────────────────────────────
    // A fresh login still completes (no forced re-verification — no new email
    // for the address) and resolves to the SAME subject.
    const before = await countMessagesTo(request, VICTIM_EMAIL);
    const recheck = await browser.newContext();
    try {
      const recheckPage = await recheck.newPage();
      await submitIdpCredentials(recheckPage, VICTIM_USERNAME, PASSWORD);
      await expectLoginCompleted(recheckPage, VICTIM_EMAIL);
      expect((await readIdTokenClaims(recheckPage)).sub).toBe(victimSub);
      expect(await countMessagesTo(request, VICTIM_EMAIL)).toBe(before);
    } finally {
      await recheck.close();
    }
  });
});
