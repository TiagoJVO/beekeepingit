import { WebStorageStateStore } from "oidc-client-ts";
import type { AuthProviderProps } from "react-oidc-context";
import type { AppConfig } from "../config/env";

/**
 * Build the react-oidc-context provider config from validated app config.
 *
 * Discovery-driven: `authority` is the issuer, and oidc-client-ts fetches every endpoint
 * from its `.well-known/openid-configuration`. No provider URL scheme is hard-coded —
 * swapping the IdP is just changing the issuer (D-7, ADR-0016, oidc-integration.md §1).
 *
 * Public client, Authorization Code + PKCE (`response_type: "code"`; PKCE is on by default
 * in oidc-client-ts) — no client secret (auth.md §3.2).
 */
export function buildOidcConfig(config: AppConfig): AuthProviderProps {
  return {
    authority: config.oidcIssuer,
    client_id: config.oidcClientId,
    redirect_uri: config.oidcRedirectUri,
    post_logout_redirect_uri: config.oidcRedirectUri,
    response_type: "code",
    scope: "openid profile email",
    // Keep the browser session across reloads; renew access tokens silently before expiry.
    automaticSilentRenew: true,
    userStore: new WebStorageStateStore({ store: window.localStorage }),
    // Strip the `?code=&state=` query the IdP appended, so a reload doesn't re-trigger the
    // code exchange.
    onSigninCallback: () => {
      window.history.replaceState({}, document.title, window.location.pathname);
    },
  };
}
