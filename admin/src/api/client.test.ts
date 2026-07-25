import { describe, expect, it, vi } from "vitest";
import { ApiError, createApiClient } from "./client";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("createApiClient", () => {
  it("attaches the bearer token and calls the /v1-prefixed path (NFR-SEC-1)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    const client = createApiClient("https://app.example", () => "tok-123", fetchMock);

    await client.get("/organizations/me");

    expect(fetchMock).toHaveBeenCalledWith(
      "https://app.example/v1/organizations/me",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer tok-123" }),
      }),
    );
  });

  it("omits the Authorization header when there is no token", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({}));
    const client = createApiClient("https://app.example", () => null, fetchMock);

    await client.get("/organizations/me");

    const init = fetchMock.mock.calls[0]![1] as RequestInit;
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined();
  });

  it("maps a 401 to an unauthorized ApiError", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({}, 401));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await expect(client.get("/organizations/me")).rejects.toMatchObject({
      name: "ApiError",
      kind: "unauthorized",
      status: 401,
    });
  });

  it("maps a 403 to a forbidden ApiError", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({}, 403));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await expect(client.get("/x")).rejects.toMatchObject({ kind: "forbidden", status: 403 });
  });

  it("maps a 404 to a not-found ApiError", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({}, 404));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await expect(client.get("/organizations/me")).rejects.toMatchObject({ kind: "not-found" });
  });

  it("maps a thrown fetch (offline) to a network ApiError", async () => {
    const fetchMock = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    const error = await client.get("/organizations/me").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).kind).toBe("network");
  });
});
