// Runtime configuration, parsed and validated from Vite env vars (VITE_*).
//
// Parsing is a pure function (no throwing at import time) so that `vite build` and unit
// tests never crash on missing env — misconfiguration surfaces as a clear in-app screen
// (see ConfigError) rather than a blank page. Validate at system boundary (coding-style).

export interface AppConfig {
  readonly oidcIssuer: string;
  readonly oidcClientId: string;
  readonly oidcRedirectUri: string;
  readonly apiBaseUrl: string;
  /** IdP self-service account page — account/password stays at the IdP (D-7). */
  readonly accountUrl: string;
  /**
   * Dev/preview-only flag that reveals the INERT quotas & rate-limit management seam
   * (NFR-RL-1 mechanism boundary / NFR-ROL-2). Quotas are DEFERRED out of v1 (D-4), so this
   * defaults to `false` and the seam ships hidden — the real screens land under EPIC-91.
   */
  readonly quotasSeamEnabled: boolean;
}

export interface ConfigResult {
  readonly config: AppConfig | null;
  /** Names of required env vars that were missing/blank. Empty when config is valid. */
  readonly missing: string[];
}

type RawEnv = Partial<Record<string, string>>;

function trimmed(value: string | undefined): string {
  return (value ?? "").trim();
}

/**
 * Parse and validate configuration from a Vite-style env map.
 *
 * @param env  env source (defaults to `import.meta.env`); injectable for tests.
 * @param origin  fallback redirect URI when VITE_OIDC_REDIRECT_URI is unset.
 */
export function readConfig(
  env: RawEnv = import.meta.env,
  origin: string = typeof window !== "undefined" ? window.location.origin : "",
): ConfigResult {
  const oidcIssuer = trimmed(env.VITE_OIDC_ISSUER);
  const oidcClientId = trimmed(env.VITE_OIDC_CLIENT_ID);
  const apiBaseUrl = trimmed(env.VITE_API_BASE_URL);
  const accountUrl = trimmed(env.VITE_ACCOUNT_URL);
  const oidcRedirectUri = trimmed(env.VITE_OIDC_REDIRECT_URI) || origin;
  // Opt-in flag; anything other than the literal "true" keeps the deferred seam hidden (D-4).
  const quotasSeamEnabled = trimmed(env.VITE_FEATURE_QUOTAS_SEAM).toLowerCase() === "true";

  const missing: string[] = [];
  if (!oidcIssuer) missing.push("VITE_OIDC_ISSUER");
  if (!oidcClientId) missing.push("VITE_OIDC_CLIENT_ID");
  if (!apiBaseUrl) missing.push("VITE_API_BASE_URL");

  if (missing.length > 0) {
    return { config: null, missing };
  }

  return {
    config: {
      oidcIssuer,
      oidcClientId,
      oidcRedirectUri,
      apiBaseUrl: apiBaseUrl.replace(/\/+$/, ""),
      // accountUrl is optional; empty string hides the "manage account" link.
      accountUrl,
      quotasSeamEnabled,
    },
    missing: [],
  };
}
