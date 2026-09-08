import { test, expect } from "@playwright/test";
import {
  enableSemantics,
  scrollFlutterViewTo,
  submitIdpCredentials,
  waitForUrlCommitted,
} from "./helpers";

/**
 * #836 — **the Sign out tap reaches the widget, and sign-out starts.**
 *
 * Deliberately narrower than slice.spec.ts's `logout revokes the session` test,
 * and deliberately independent of it. That test asserts the whole RP-initiated
 * round trip — end-session, back to `/login`, and the IdP asking for a password
 * again — which needs the provider's invalidation flow to be configured (#237).
 * This one asserts only the half that is entirely the client's: that tapping
 * "Sign out" on the Account screen actually invokes `AuthController.logout()`.
 *
 * It exists because that half failed silently for weeks and was mistaken for
 * something else entirely. Sign out is the LAST child of the Account screen's
 * `SingleChildScrollView`, so at this suite's 1280x720 viewport it sits below
 * the fold — and a Flutter-web semantics click on an off-screen target is a
 * **silent no-op**: Playwright clicks the absolutely-positioned DOM mirror,
 * Flutter ignores it because the real widget is not on screen, and nothing at
 * all happens (see `scrollFlutterViewTo`). In one instrumented CI run, four of
 * five sign-out attempts never reached the first line of `logout()`. The
 * resulting 60s `waitForURL` timeout was read as a wedged browser main thread,
 * then as a stalled PowerSync wipe, then as a Riverpod teardown race — three
 * wrong diagnoses of a click that never landed (#836).
 *
 * Keeping this separate from the round-trip test is what makes a future red run
 * self-diagnosing: this one red means the app never started signing out; this
 * one green and the round-trip test red means the client did its part and the
 * provider did not.
 *
 * The assertion stops at "the app left `/account`", which is the first
 * observable effect of `logout()` (it clears the session, the router redirects)
 * and is true whether or not the provider then bounces the browser back. It
 * makes no claim about where the browser ends up — that is #237's test's job.
 */
const TEST_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const TEST_PASS = process.env.E2E_PASS ?? "dev-password123";

test("tapping Sign out actually starts sign-out (#836, FR-AU-1, NFR-SEC-1)", async ({ page }) => {
  await submitIdpCredentials(page, TEST_USER, TEST_PASS);
  // The OIDC callback is a full page load, so this wait settles on `commit`
  // for the same reason the post-logout one does — see `waitForUrlCommitted`.
  await waitForUrlCommitted(page, /\/home/);
  await enableSemantics(page);
  await expect(page.getByRole("heading", { name: "Home" })).toBeVisible({ timeout: 30_000 });

  await page.getByRole("button", { name: "Account settings" }).click();
  await page.waitForURL(/\/account/, { timeout: 30_000 });
  await enableSemantics(page);

  const signOut = page.getByRole("button", { name: "Sign out" });
  await expect(signOut).toBeVisible({ timeout: 30_000 });
  await scrollFlutterViewTo(page, signOut);
  await signOut.click();

  // `expect.poll` on `page.url()` rather than `waitForURL`: the driver answers
  // it without running any page JavaScript, and it asserts the URL predicate
  // and nothing else — no document lifecycle event has to fire for this to be
  // true (#836's other failure mode; see `waitForUrlCommitted`).
  await expect
    .poll(() => page.url(), {
      timeout: 30_000,
      message:
        "Sign out was clicked but the app never left /account. Either the tap did not reach " +
        "the widget (the Flutter-web off-screen silent no-op — see scrollFlutterViewTo) or " +
        "AuthController.logout() did not run.",
    })
    .not.toMatch(/\/account/);
});
