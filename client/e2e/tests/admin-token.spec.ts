import { test, expect } from "@playwright/test";
import { ADMIN_ORIGIN, readAdminAccessTokenClaims, submitAuthentikForm } from "./helpers";

/**
 * Admin-token claim-shape e2e (#460, #456, NFR-SEC-1, NFR-TST-1).
 *
 * The admin app authenticates as its OWN OIDC client (`beekeepingit-admin`),
 * distinct from the PWA's `beekeepingit-pwa`. The domain services are frozen to
 * ONE issuer + ONE audience (`OIDC_AUDIENCE=beekeepingit-pwa`, checked by
 * containment) — admin tokens are accepted only because a scope mapping attached
 * ONLY to the admin provider OVERRIDES the minted `iss`/`aud` so an admin token
 * carries `iss` = the beekeepingit issuer and `aud` = [beekeepingit-admin,
 * beekeepingit-pwa] (blueprint `scope-admin-audience`, oidc-integration.md §3.1).
 *
 * That override rides version-sensitive Authentik internals (oidc-integration.md
 * §8 watch-list). The pre-existing admin path in CI only proved "the admin image
 * comes up" — it never asserted the token's CLAIM SHAPE, so an Authentik bump
 * that broke the override would be a silent prod 401, not a red CI. This spec
 * closes that gap: it drives a REAL Authorization Code + PKCE login through the
 * admin app (so the /authorize + /token path — and the override mapping — runs),
 * then asserts the minted ACCESS token (the credential the services validate):
 *   - `iss` == the beekeepingit issuer (NOT the admin provider's own
 *     `.../application/o/beekeepingit-admin/`), and
 *   - `aud` CONTAINS BOTH `beekeepingit-admin` AND `beekeepingit-pwa`.
 * Either missing fails the job loudly — the whole point (catch the regression in
 * CI, not prod).
 *
 * Opt-in via E2E_ADMIN_ORIGIN (helm-e2e.yml sets it to the deployed admin host);
 * self-skips otherwise (a local PWA-only run has no admin app served). Reuses the
 * blueprint-seeded admin test user — the same creds the other specs use.
 */

const ADMIN_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const ADMIN_PASS = process.env.E2E_PASS ?? "dev-password123";
// The beekeepingit issuer the services are pinned to (and the admin build's
// VITE_OIDC_ISSUER). The override makes the admin token claim exactly this.
const EXPECTED_ISSUER =
  process.env.E2E_OIDC_ISSUER ?? "https://auth.beekeepingit.local:8443/application/o/beekeepingit/";

// The admin origin, anchored — a login that completed lands back here (the OIDC
// callback), whereas anything still on the auth host means the flow didn't
// finish. Escape it for use in a RegExp (it contains . and : metacharacters).
const adminOriginRe = ADMIN_ORIGIN
  ? new RegExp(`^${ADMIN_ORIGIN.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`)
  : /$^/;

test.describe("admin token iss/aud override (#460)", () => {
  test.skip(!ADMIN_ORIGIN, "E2E_ADMIN_ORIGIN unset — admin app not served (local PWA-only run)");

  test("admin login mints a token with the overridden iss + dual aud", async ({ page }) => {
    // Navigate to the admin app, tolerating a cold stack: like the PWA route, the
    // gateway can transiently answer 5xx right after the pod is marked ready
    // (endpoints/first-request not warm). Retry until the SPA's Sign in button
    // paints, not just until goto() resolves.
    const deadline = Date.now() + 120_000;
    const signIn = page.getByRole("button", { name: /sign in/i });
    for (;;) {
      const resp = await page
        .goto(`${ADMIN_ORIGIN}/`, { waitUntil: "domcontentloaded" })
        .catch(() => null);
      const serverError = resp != null && resp.status() >= 500;
      if (!serverError) {
        const painted = await signIn
          .waitFor({ state: "visible", timeout: 20_000 })
          .then(() => true)
          .catch(() => false);
        if (painted) break;
      }
      if (Date.now() > deadline) {
        throw new Error(
          `admin app never rendered its Sign in screen (last HTTP ${resp?.status() ?? "unknown"})`,
        );
      }
      await page.waitForTimeout(3_000);
    }

    // Click the admin app's Sign in → oidc-client-ts signinRedirect: it fetches OIDC
    // discovery from the beekeepingit issuer, then redirects to the auth host. If that
    // discovery/JWKS fetch is CORS-blocked (the admin origin must be an allowed CORS
    // origin on the pwa provider — see the blueprint), the admin app instead shows its
    // own "Sign-in failed" screen and never leaves the admin origin. Wait for the hop to
    // the auth host and surface THAT error fast, rather than hanging the full test budget
    // in submitAuthentikForm waiting for an IdP form that will never appear.
    await signIn.click();
    try {
      await page.waitForURL(/\/\/auth\./, { timeout: 45_000 });
    } catch {
      const detail = await page
        .getByRole("main")
        .innerText()
        .catch(() => "");
      throw new Error(
        `admin sign-in never reached the IdP (still at ${page.url()}): ${detail.replace(/\s+/g, " ").slice(0, 300)}`,
      );
    }
    await submitAuthentikForm(page, ADMIN_USER, ADMIN_PASS);

    // Back on the admin origin means the code exchange completed; the access
    // token is now persisted by oidc-client-ts.
    await page.waitForURL(adminOriginRe, { timeout: 60_000 });

    const claims = await readAdminAccessTokenClaims(page);

    // iss: the override aligned the admin token onto the beekeepingit issuer. If
    // the override broke, Authentik would emit the admin provider's OWN issuer
    // (.../application/o/beekeepingit-admin/) and this equality fails loudly.
    expect(
      claims.iss,
      "admin token iss must be the beekeepingit issuer, not the admin provider's own",
    ).toBe(EXPECTED_ISSUER);

    // aud: normalize to an array (a single-aud token would be a string) and
    // require BOTH audiences — beekeepingit-pwa is the one the services check by
    // containment, beekeepingit-admin proves the override kept the admin client's
    // own audience too.
    const aud = Array.isArray(claims.aud) ? (claims.aud as unknown[]) : [claims.aud];
    expect(aud, "admin token aud must contain the frozen services audience").toContain(
      "beekeepingit-pwa",
    );
    expect(aud, "admin token aud must contain the admin client's own audience").toContain(
      "beekeepingit-admin",
    );
  });
});
