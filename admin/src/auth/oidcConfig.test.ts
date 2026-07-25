import { describe, expect, it } from "vitest";
import { buildOidcConfig } from "./oidcConfig";
import type { AppConfig } from "../config/env";

const config: AppConfig = {
  oidcIssuer: "https://auth.example/application/o/beekeepingit/",
  oidcClientId: "beekeepingit-admin",
  oidcRedirectUri: "http://localhost:5174",
  apiBaseUrl: "https://app.example",
  accountUrl: "",
};

describe("buildOidcConfig", () => {
  // AuthProviderProps is a union (props form | userManager form); index it as a record to
  // read the OIDC settings this factory sets on the props form.
  function settings() {
    return buildOidcConfig(config) as unknown as Record<string, unknown>;
  }

  it("maps config onto an Authorization Code + PKCE provider config", () => {
    const c = settings();
    expect(c.authority).toBe(config.oidcIssuer);
    expect(c.client_id).toBe("beekeepingit-admin");
    expect(c.redirect_uri).toBe("http://localhost:5174");
    // Authorization Code flow (PKCE is on by default in oidc-client-ts) — no implicit tokens.
    expect(c.response_type).toBe("code");
    expect(c.scope).toContain("openid");
  });

  it("uses the redirect URI for post-logout too", () => {
    expect(settings().post_logout_redirect_uri).toBe("http://localhost:5174");
  });
});
