import { describe, expect, it } from "vitest";
import { readConfig } from "./env";

const validEnv = {
  VITE_OIDC_ISSUER: "https://auth.example/application/o/beekeepingit/",
  VITE_OIDC_CLIENT_ID: "beekeepingit-admin",
  VITE_API_BASE_URL: "https://app.example",
  VITE_ACCOUNT_URL: "https://auth.example/if/user/#/settings",
};

describe("readConfig", () => {
  it("parses a complete env into config", () => {
    const { config, missing } = readConfig(validEnv, "http://localhost:5174");
    expect(missing).toEqual([]);
    expect(config).toEqual({
      oidcIssuer: validEnv.VITE_OIDC_ISSUER,
      oidcClientId: "beekeepingit-admin",
      oidcRedirectUri: "http://localhost:5174",
      apiBaseUrl: "https://app.example",
      accountUrl: validEnv.VITE_ACCOUNT_URL,
      quotasSeamEnabled: false,
    });
  });

  it("keeps the deferred quotas seam disabled by default (D-4)", () => {
    const { config } = readConfig(validEnv, "http://localhost");
    expect(config?.quotasSeamEnabled).toBe(false);
  });

  it("enables the quotas seam only for the literal flag value 'true'", () => {
    const on = readConfig({ ...validEnv, VITE_FEATURE_QUOTAS_SEAM: "true" }, "http://localhost");
    expect(on.config?.quotasSeamEnabled).toBe(true);

    const off = readConfig({ ...validEnv, VITE_FEATURE_QUOTAS_SEAM: "1" }, "http://localhost");
    expect(off.config?.quotasSeamEnabled).toBe(false);
  });

  it("defaults the redirect URI to the origin when unset", () => {
    const { config } = readConfig(validEnv, "http://localhost:9999");
    expect(config?.oidcRedirectUri).toBe("http://localhost:9999");
  });

  it("prefers an explicit redirect URI over the origin", () => {
    const { config } = readConfig(
      { ...validEnv, VITE_OIDC_REDIRECT_URI: "https://admin.example/cb" },
      "http://localhost:5174",
    );
    expect(config?.oidcRedirectUri).toBe("https://admin.example/cb");
  });

  it("strips a trailing slash from the API base URL", () => {
    const { config } = readConfig({ ...validEnv, VITE_API_BASE_URL: "https://app.example/" });
    expect(config?.apiBaseUrl).toBe("https://app.example");
  });

  it("reports each missing required var and returns no config", () => {
    const { config, missing } = readConfig({}, "http://localhost");
    expect(config).toBeNull();
    expect(missing).toEqual(["VITE_OIDC_ISSUER", "VITE_OIDC_CLIENT_ID", "VITE_API_BASE_URL"]);
  });

  it("treats blank/whitespace values as missing", () => {
    const { missing } = readConfig({ ...validEnv, VITE_OIDC_CLIENT_ID: "   " });
    expect(missing).toContain("VITE_OIDC_CLIENT_ID");
  });
});
