// Minimal typed API client for the platform REST API.
//
// Every request carries the OIDC access token as a Bearer credential (NFR-SEC-1). The
// server is authoritative: it rejects missing/expired tokens with 401 and non-admin
// callers with 403 — this client surfaces those as typed errors for the UI to react to.
//
// Beyond plain reads, the client supports the optimistic-concurrency write flow the org
// management screen needs (FR-TEN-2): reads expose the response `ETag`, and PATCH echoes it
// back as `If-Match` so a stale write is rejected server-side with a 409 (surfaced here as a
// typed `conflict` error). Validation failures (422) carry the RFC 9457 problem body so the
// UI can map field-level errors back onto the form.

export type ApiErrorKind =
  "unauthorized" | "forbidden" | "not-found" | "conflict" | "validation" | "network" | "http";

/** A single field-level validation error (RFC 9457 `errors[]`, `422`). */
export interface FieldError {
  readonly field: string;
  readonly code?: string;
  readonly message: string;
}

/** RFC 9457 Problem Details — the `application/problem+json` body of any non-2xx response. */
export interface ProblemDetails {
  readonly title?: string;
  readonly detail?: string;
  readonly status?: number;
  readonly code?: string;
  readonly errors?: readonly FieldError[];
}

export class ApiError extends Error {
  readonly kind: ApiErrorKind;
  readonly status: number;
  /** The parsed problem body, when the server returned one (validation errors live here). */
  readonly problem?: ProblemDetails;

  constructor(kind: ApiErrorKind, status: number, message: string, problem?: ProblemDetails) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = status;
    this.problem = problem;
  }
}

/** Supplies the current access token, or null when unauthenticated. */
export type TokenProvider = () => string | null | undefined;

/** A response body paired with its `ETag` version stamp (null when the server omits one). */
export interface ETagged<T> {
  readonly data: T;
  readonly etag: string | null;
}

export interface ApiClient {
  get<T>(path: string): Promise<T>;
  /** Like `get`, but also returns the response `ETag` for a later optimistic-concurrency write. */
  getWithETag<T>(path: string): Promise<ETagged<T>>;
  /**
   * PATCH a resource. When `ifMatch` is provided it is sent as the `If-Match` header so the
   * server rejects a stale write with `409` (surfaced as an `ApiError` of kind `conflict`).
   */
  patch<T>(path: string, body: unknown, options?: { ifMatch?: string | null }): Promise<ETagged<T>>;
}

function kindForStatus(status: number): ApiErrorKind {
  if (status === 401) return "unauthorized";
  if (status === 403) return "forbidden";
  if (status === 404) return "not-found";
  if (status === 409) return "conflict";
  if (status === 422) return "validation";
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
  async function send(path: string, init: RequestInit): Promise<Response> {
    const token = getToken();
    const headers: Record<string, string> = {
      Accept: "application/json",
      ...(init.headers as Record<string, string> | undefined),
    };
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }

    let response: Response;
    try {
      response = await fetchImpl(`${baseUrl}/v1${path}`, { ...init, headers });
    } catch {
      throw new ApiError("network", 0, `Network error calling ${path}`);
    }

    if (!response.ok) {
      throw await errorFrom(response, init.method ?? "GET", path);
    }

    return response;
  }

  async function errorFrom(response: Response, method: string, path: string): Promise<ApiError> {
    const kind = kindForStatus(response.status);
    const problem = await readProblem(response);
    const message = problem?.detail ?? problem?.title ?? `${method} ${path} → ${response.status}`;
    return new ApiError(kind, response.status, message, problem);
  }

  return {
    async get<T>(path: string): Promise<T> {
      const response = await send(path, {});
      return (await response.json()) as T;
    },
    async getWithETag<T>(path: string): Promise<ETagged<T>> {
      const response = await send(path, {});
      return { data: (await response.json()) as T, etag: response.headers.get("ETag") };
    },
    async patch<T>(
      path: string,
      body: unknown,
      options?: { ifMatch?: string | null },
    ): Promise<ETagged<T>> {
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (options?.ifMatch) {
        headers["If-Match"] = options.ifMatch;
      }
      const response = await send(path, {
        method: "PATCH",
        body: JSON.stringify(body),
        headers,
      });
      return { data: (await response.json()) as T, etag: response.headers.get("ETag") };
    },
  };
}

/** Best-effort parse of an `application/problem+json` body; never throws. */
async function readProblem(response: Response): Promise<ProblemDetails | undefined> {
  const contentType = response.headers.get("Content-Type") ?? "";
  if (!contentType.includes("json")) {
    return undefined;
  }
  try {
    return (await response.json()) as ProblemDetails;
  } catch {
    return undefined;
  }
}
