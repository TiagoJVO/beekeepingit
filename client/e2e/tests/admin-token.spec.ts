import { test, expect } from "@playwright/test";
import { ADMIN_ORIGIN, adminSignIn, readAdminAccessTokenClaims } from "./helpers";

/**
 * Admin-token claim-shape e2e (#460 iss/aud override, #465 platform-operator
 * claim; #456, EPIC-18 #463, NFR-SEC-1, NFR-ROL-1, NFR-TST-1).
 *
 * The admin app authenticates as its OWN OIDC client (`beekeepingit-admin`),
 * distinct from the PWA's `beekeepingit-pwa`. The domain services are frozen to
 * ONE issuer + ONE audience (`OIDC_AUDIENCE=beekeepingit-pwa`, checked by
 * containment) — admin tokens are accepted only because a scope mapping attached
 * ONLY to the admin provider OVERRIDES the minted `iss`/`aud` so an admin token
 * carries `iss` = the beekeepingit issuer and `aud` = [beekeepingit-admin,
 * beekeepingit-pwa] (blueprint `scope-admin-audience`, oidc-integration.md §3.1).
 * A second admin-only mapping (`scope-platform-operator`, §3.2) emits the
 * `platform_operator` boolean the services will authorize the platform tier on.
 *
 * Both overrides ride version-sensitive Authentik internals (oidc-integration.md
 * §8 watch-list). The pre-existing admin path in CI only proved "the admin image
 * comes up" — it never asserted the token's CLAIM SHAPE, so an Authentik bump
 * that broke either mapping would be a silent prod failure (a 401 for the
 * iss/aud override; a platform-tier authorization that silently opens or closes
 * for the operator claim), not a red CI. This spec closes that gap: it drives
 * REAL Authorization Code + PKCE logins through the admin app (so the /authorize
 * + /token path — and both mappings — run), then asserts the minted ACCESS token
 * (the credential the services validate).
 *
 * Opt-in via E2E_ADMIN_ORIGIN (helm-e2e.yml sets it to the deployed admin host);
 * self-skips otherwise (a local PWA-only run has no admin app served). Reuses the
 * blueprint-seeded users — the same creds the other specs use.
 */

// Seeded IN the `platform-operator` group (blueprint `user-test-beekeeper`).
const ADMIN_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const ADMIN_PASS = process.env.E2E_PASS ?? "dev-password123";
// Seeded verified but deliberately NOT in `platform-operator` (blueprint
// `user-non-operator`, #465) — the negative half of the claim proof.
const NON_OPERATOR_USER = process.env.E2E_NON_OPERATOR_USER ?? "non.operator@beekeepingit.local";
const NON_OPERATOR_PASS = process.env.E2E_NON_OPERATOR_PASS ?? ADMIN_PASS;
// The beekeepingit issuer the services are pinned to (and the admin build's
// VITE_OIDC_ISSUER). The override makes the admin token claim exactly this.
const EXPECTED_ISSUER =
  process.env.E2E_OIDC_ISSUER ?? "https://auth.beekeepingit.local:8443/application/o/beekeepingit/";

test.describe("admin token iss/aud override (#460)", () => {
  test.skip(!ADMIN_ORIGIN, "E2E_ADMIN_ORIGIN unset — admin app not served (local PWA-only run)");

  test("admin login mints a token with the overridden iss + dual aud", async ({ page }) => {
    await adminSignIn(page, ADMIN_USER, ADMIN_PASS);

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

/**
 * The platform tier (EPIC-18 #463): an app owner who administers EVERY
 * organization, as opposed to EPIC-10's org-scoped `admin` (a member of ONE org).
 * That authority is minted here as the `platform_operator` boolean, derived
 * server-side from the caller's real `platform-operator` group membership — the
 * claim #466 will authorize on. Proved BOTH ways, because either direction
 * failing is a security bug: a false negative locks the platform admin out, a
 * false positive hands every tenant's data to a non-operator.
 */
test.describe("platform-operator claim (#465)", () => {
  test.skip(!ADMIN_ORIGIN, "E2E_ADMIN_ORIGIN unset — admin app not served (local PWA-only run)");

  test("an operator's admin token carries platform_operator: true", async ({ page }) => {
    await adminSignIn(page, ADMIN_USER, ADMIN_PASS);

    const claims = await readAdminAccessTokenClaims(page);

    // Strict identity, not truthiness: #466 reads a JSON boolean, so a string
    // "true" (or any other shape drift from an Authentik bump) must fail here
    // rather than quietly work on one side of the boundary and not the other.
    expect(
      claims.platform_operator,
      "a platform-operator's admin access token must carry platform_operator: true",
    ).toBe(true);
  });

  test("a non-operator's admin token carries platform_operator: false", async ({ page }) => {
    await adminSignIn(page, NON_OPERATOR_USER, NON_OPERATOR_PASS);

    const claims = await readAdminAccessTokenClaims(page);

    // Explicitly `false`, not merely absent: a present `false` proves the mapping
    // RAN and evaluated this user's real memberships. Asserting only "not true"
    // would still pass if the mapping had silently stopped being applied at all,
    // which is exactly the regression the positive case above must catch.
    expect(
      claims.platform_operator,
      "a non-operator's admin access token must carry platform_operator: false",
    ).toBe(false);
  });
});
