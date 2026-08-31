import { expect, Page, test } from "@playwright/test";

import { enableSemantics, gotoAppRoot } from "./helpers";

/**
 * Upstream federation — "Continue with <source>" (#363, FR-ONB-1, D-7, D-18).
 *
 * WHAT THIS CAN AND CANNOT PROVE. A live journey through real Google is not
 * automatable (consent screen + bot detection) and must never run in CI, so
 * this spec proves the OUTBOUND half — everything from the app's own button up
 * to the request that leaves for the upstream — against the dev/CI stand-in
 * source. That stand-in is a generic `openidconnect` source configured with the
 * IDENTICAL posture as the Google one (same model, same `OAuthRedirect` view,
 * same `SourceFlowManager`, `user_matching_mode: username_link` with the #364
 * resolver attached, `enrollment_flow: beekeepingit-source-enrollment` per
 * #365), so the wiring under test is genuinely the same wiring, not a mock of
 * it. Only the upstream differs: its authorize URL points at an inert,
 * reachable endpoint, and the spec asserts the outbound REQUEST to it rather
 * than any landing page (that endpoint answers 204, and a browser never
 * commits a navigation to a 204).
 *
 * The INBOUND half — what authentik decides when an upstream identity comes
 * back, i.e. the deny/enroll posture (#364/#365) and the unchanged `sub` — is
 * proven by the `SourceFlowManager` probe helm-e2e.yml runs in the authentik
 * worker (infra/ci/authentik-federation-probe.py). The blueprint config itself
 * is pinned offline by scripts/check-federation-source-posture.sh. Completing a
 * real Google sign-in stays a documented manual check (infra/README.md).
 *
 * Test 1 below is the load-bearing one: the hint machinery binds a redirect
 * stage into the DEFAULT authentication flow, so a policy that started
 * returning true would hijack every password login on this deployment. It runs
 * against a stack where that stage is real and enabled.
 */

// The blueprint's dev/CI stand-in source. Absent in staging/prod, where the
// Google source takes its place — see charts/authentik/values.yaml.
const STUB_SLUG = "federation-stub";
// Locale-independent pin, deliberately NOT a text selector. authentik labels
// the button "Continue with {name}", and that template IS a localized msgid —
// it merely happens to be untranslated in the shipped pt-BR catalog at
// 2026.5.4, so `getByRole("button", { name: "Continue with ..." })` would pass
// today for the wrong reason and break on a version bump that fills the
// translation in (watch-listed in oidc-integration.md §8). The `name`
// attribute is `source-<kebab-cased source name>` and carries no localization;
// the prefix match also avoids depending on how the kebab-caser splits a name.
// dev/CI enables exactly one source, so the prefix is unambiguous here.
const STUB_BUTTON = 'button[name^="source-"]';

const AUTH_ORIGIN = process.env.E2E_AUTH_ORIGIN ?? "https://auth.beekeepingit.local:8443";
// Only used as a syntactically valid `redirect_uri` on the authorize requests
// the IdP-side tests construct — nothing ever redirects back to it, because
// those flows stop at the upstream. It must still be a registered redirect for
// the `beekeepingit-pwa` client or authentik rejects the request outright.
const APP_ORIGIN = process.env.E2E_BASE_URL ?? "https://app.beekeepingit.local:8443";
const DISCOVERY_URL = `${AUTH_ORIGIN}/application/o/beekeepingit/.well-known/openid-configuration`;

/**
 * Builds an authorize request for the `beekeepingit-pwa` client carrying a
 * federation hint, WITHOUT driving the app's sign-in button first.
 *
 * Why not just click the button and replay the URL it produces: that click
 * leaves an in-progress flow plan in authentik's Django session, and
 * `FlowExecutorView.dispatch` CONTINUES an existing plan for the same flow
 * rather than re-planning it — so a replay resumes at whatever stage the click
 * already reached and never revisits the order-5 redirect stage. That made
 * these specs fail on the first attempt and pass only on Playwright's retry
 * (which starts from a fresh context), across three CI runs.
 *
 * Discovery is fetched from INSIDE the page, not with Playwright's `request`
 * fixture: that fixture is a Node-side HTTP client and does not honour the
 * browser's `--host-resolver-rules`, so `auth.beekeepingit.local` simply does
 * not resolve for it. Fetching in-page is also what the real client does, and
 * the blueprint already grants this origin CORS on the discovery document
 * (the PWA provider's strict bare-origin redirect_uri entry exists for exactly
 * that).
 *
 * No coverage is lost by not using the button here: that "Continue with
 * Google" sends precisely this request, with PKCE and state intact, is pinned
 * by client/test/core/auth/auth_controller_test.dart. What is unproven there,
 * and proven here, is what authentik DOES with the hint.
 */
async function hintedAuthorizeUrl(page: Page, hint: string, state: string): Promise<string> {
  const authorizationEndpoint = await page.evaluate(
    async (url) => (await (await fetch(url)).json()).authorization_endpoint as string,
    DISCOVERY_URL,
  );
  expect(
    authorizationEndpoint,
    "OIDC discovery should advertise an authorize endpoint",
  ).toBeTruthy();

  const hinted = new URL(authorizationEndpoint);
  hinted.searchParams.set("client_id", "beekeepingit-pwa");
  hinted.searchParams.set("response_type", "code");
  hinted.searchParams.set("redirect_uri", APP_ORIGIN);
  hinted.searchParams.set("scope", "openid profile email");
  hinted.searchParams.set("state", state);
  // The one parameter under test — the same one the app's button sends.
  hinted.searchParams.set("beekeepingit_idp", hint);
  return hinted.toString();
}

test.describe("upstream federation (#363)", () => {
  test("the app's sign-in screen offers a federated action next to Sign in", async ({ page }) => {
    await gotoAppRoot(page);
    await enableSemantics(page);

    // Both actions are present, and the federated one carries its own
    // externalized label (EN here; the PT string is pinned by the Flutter
    // l10n unit tests, which don't need a live stack).
    await expect(page.getByRole("button", { name: /sign in/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /continue with google/i })).toBeVisible();
  });

  // The negative case, and the reason this spec is worth its runtime: the
  // redirect stage is bound into the default authentication flow on this very
  // stack. A plain "Sign in" must still reach the provider's own login form.
  test("plain Sign in is NOT hijacked by the federation hint machinery", async ({ page }) => {
    await gotoAppRoot(page);
    await enableSemantics(page);

    await page.getByRole("button", { name: /sign in/i }).click();

    // Lands on authentik's identification stage — the username/password form —
    // not on any source redirect.
    await page.waitForURL(new RegExp(`^${AUTH_ORIGIN.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`), {
      timeout: 60_000,
    });
    await expect(page.locator('input[name="uidField"]')).toBeVisible({ timeout: 30_000 });
    // ...and the source button is offered alongside it, which is the AC's
    // "alongside username/password" (that form is the only surface in the
    // system that HAS a username and password).
    await expect(page.locator(STUB_BUTTON)).toBeVisible();
  });

  // The one-hop chain, end to end up to the upstream: app button -> standard
  // OIDC authorize request carrying `beekeepingit_idp` -> authentik stores it
  // as the flow's `next` -> hint policy resolves the slug against enabled
  // sources -> redirect stage auto-follows to /source/oauth/login/<slug>/ ->
  // OAuthRedirect builds the upstream authorize request. Asserting the
  // parameters on that outbound request proves every link in the chain fired.
  test("a federated action reaches the upstream in one hop, with a well-formed authorize request", async ({
    page,
  }) => {
    // Boot the app only to get a page on the app origin that discovery can be
    // fetched from — deliberately no click, so no flow plan is ever created.
    await gotoAppRoot(page);
    const hinted = await hintedAuthorizeUrl(page, STUB_SLUG, "e2e-federation-state");

    // Assert on the outbound REQUEST, not on where the browser ends up: the
    // stand-in's authorize URL points at authentik's `/-/health/live/`, which
    // answers 204 No Content, and a browser does not commit a navigation to a
    // 204 — asserting on the resulting page URL would be asserting on
    // undefined behaviour. The request is also the closer match to the claim:
    // the redirect chain reached the upstream with these parameters,
    // regardless of what the upstream chose to answer.
    const upstreamRequest = page.waitForRequest((req) => req.url().includes("/-/health/live/"), {
      timeout: 60_000,
    });
    // No click anywhere: the redirect stage auto-follows. The goto's own
    // promise is deliberately not awaited for success — its final response is
    // that 204, which surfaces as an aborted navigation.
    const navigation = page.goto(hinted).catch(() => null);

    const upstream = new URL((await upstreamRequest).url());
    await navigation;
    expect(upstream.searchParams.get("client_id")).toBe("beekeepingit-federation-stub");
    expect(upstream.searchParams.get("response_type")).toBe("code");
    // The callback authentik will accept the upstream's response on — this is
    // the exact shape the Google Cloud OAuth client must be configured with
    // (infra/README.md documents it for the real thing).
    expect(upstream.searchParams.get("redirect_uri")).toContain(
      `/source/oauth/callback/${STUB_SLUG}/`,
    );
    expect(upstream.searchParams.get("state")).toBeTruthy();
    expect(upstream.searchParams.get("scope") ?? "").toContain("openid");
  });

  // #365 opened self-service registration THROUGH a federated sign-in — but
  // the flow that writes the account is fed exclusively by the resolver's
  // properties, so it must be unreachable outside that context: a browser
  // walking straight into it would otherwise reach a user_write stage with
  // whatever the session holds. The flow carries an SSO-only policy; this
  // pins the refusal through the executor's own JSON API (component name, not
  // display text — the text is a localized msgid, watch-listed in
  // oidc-integration.md §8).
  test("the source-enrollment flow cannot be entered outside a federated sign-in (#365)", async ({
    page,
  }) => {
    // Any auth-origin page works — the fetch below must be same-origin. The
    // login page is the cheapest one that always exists.
    await page.goto(`${AUTH_ORIGIN}/if/flow/default-authentication-flow/`);
    const challenge = await page.evaluate(async () => {
      const res = await fetch("/api/v3/flows/executor/beekeepingit-source-enrollment/?query=", {
        headers: { Accept: "application/json" },
      });
      return (await res.json()) as { component?: string };
    });
    expect(
      challenge.component,
      `direct entry into the source-enrollment flow returned ${JSON.stringify(challenge)}`,
    ).toBe("ak-stage-access-denied");
  });

  // A hint naming something this deployment does not have must degrade to a
  // normal login, never to an error page or an open redirect. The policy
  // whitelists against enabled sources in authentik's own DB, so this also
  // pins that a crafted parameter cannot steer the redirect anywhere.
  test("an unknown federation hint falls through to the normal login form", async ({ page }) => {
    // Same state-free construction as the one-hop test — otherwise this could
    // land on the identification form because a prior plan was already there,
    // rather than because the hint was correctly refused.
    await gotoAppRoot(page);
    const hinted = await hintedAuthorizeUrl(
      page,
      "https://evil.example/not-a-source",
      "e2e-unknown-hint-state",
    );
    await page.goto(hinted);

    await expect(page.locator('input[name="uidField"]')).toBeVisible({ timeout: 30_000 });
    expect(page.url()).toContain(AUTH_ORIGIN);
  });
});
