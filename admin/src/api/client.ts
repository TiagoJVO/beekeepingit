// Minimal typed API client for the platform REST API.
//
// Every request carries the OIDC access token as a Bearer credential (NFR-SEC-1). The
// server is authoritative: it rejects missing/expired tokens with 401 and non-admin
// callers with 403 — this client surfaces those as typed errors for the UI to react to.

export type ApiErrorKind = "unauthorized" | "forbidden" | "not-found" | "network" | "http";

export class ApiError extends Error {
  readonly kind: ApiErrorKind;
  readonly status: number;

  constructor(kind: ApiErrorKind, status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = status;
  }
}

/** Supplies the current access token, or null when unauthenticated. */
export type TokenProvider = () => string | null | undefined;

export interface ApiClient {
  get<T>(path: string): Promise<T>;
}

function kindForStatus(status: number): ApiErrorKind {
  if (status === 401) return "unauthorized";
  if (status === 403) return "forbidden";
  if (status === 404) return "not-found";
  return "http";
}

/**
 * Create a typed API client bound to a base URL and a token provider.
 *
 * @param baseUrl  API host, without a trailing slash (e.g. https://app…:8443).
 * @param getToken  returns the current bearer token (from react-oidc-context).
 * @param fetchImpl  injectable fetch (defaults to global) — eases testing.
 */
export function createApiClient(
  baseUrl: string,
  getToken: TokenProvider,
  fetchImpl: typeof fetch = fetch,
): ApiClient {
  async function request<T>(path: string): Promise<T> {
    const token = getToken();
    const headers: Record<string, string> = { Accept: "application/json" };
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }

    let response: Response;
    try {
      response = await fetchImpl(`${baseUrl}/v1${path}`, { headers });
    } catch {
      throw new ApiError("network", 0, `Network error calling ${path}`);
    }

    if (!response.ok) {
      throw new ApiError(
        kindForStatus(response.status),
        response.status,
        `GET ${path} → ${response.status}`,
      );
    }

    return (await response.json()) as T;
  }

  return {
    get: request,
  };
}
