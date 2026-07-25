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

describe("createApiClient.getWithETag", () => {
  it("returns the body together with the response ETag", async () => {
    const response = new Response(JSON.stringify({ id: "o1" }), {
      status: 200,
      headers: { "Content-Type": "application/json", ETag: '"v7"' },
    });
    const fetchMock = vi.fn().mockResolvedValue(response);
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    const result = await client.getWithETag<{ id: string }>("/organizations/me");

    expect(result).toEqual({ data: { id: "o1" }, etag: '"v7"' });
  });
});

describe("createApiClient.patch", () => {
  it("sends the body and echoes the ETag back as If-Match (FR-TEN-2)", async () => {
    const response = new Response(JSON.stringify({ id: "o1", name: "New" }), {
      status: 200,
      headers: { "Content-Type": "application/json", ETag: '"v8"' },
    });
    const fetchMock = vi.fn().mockResolvedValue(response);
    const client = createApiClient("https://app.example", () => "tok", fetchMock);

    const result = await client.patch<{ id: string; name: string }>(
      "/organizations/o1",
      { name: "New" },
      { ifMatch: '"v7"' },
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "https://app.example/v1/organizations/o1",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ name: "New" }),
        headers: expect.objectContaining({
          "If-Match": '"v7"',
          "Content-Type": "application/json",
          Authorization: "Bearer tok",
        }),
      }),
    );
    expect(result).toEqual({ data: { id: "o1", name: "New" }, etag: '"v8"' });
  });

  it("omits If-Match when no ETag is supplied", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ id: "o1" }));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await client.patch("/organizations/o1", { name: "X" });

    const init = fetchMock.mock.calls[0]![1] as RequestInit;
    expect((init.headers as Record<string, string>)["If-Match"]).toBeUndefined();
  });

  it("maps a 409 to a conflict ApiError (stale If-Match)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ title: "Conflict" }, 409));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await expect(
      client.patch("/organizations/o1", { name: "X" }, { ifMatch: '"stale"' }),
    ).rejects.toMatchObject({ kind: "conflict", status: 409 });
  });

  it("maps a 422 to a validation ApiError and parses the problem field errors", async () => {
    const problem = {
      title: "Validation failed",
      status: 422,
      errors: [{ field: "name", code: "required", message: "name must not be empty" }],
    };
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(problem), {
        status: 422,
        headers: { "Content-Type": "application/problem+json" },
      }),
    );
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    const error = (await client
      .patch("/organizations/o1", { name: "" }, { ifMatch: '"v1"' })
      .catch((e: unknown) => e)) as ApiError;

    expect(error.kind).toBe("validation");
    expect(error.status).toBe(422);
    expect(error.problem?.errors?.[0]).toMatchObject({ field: "name", code: "required" });
  });
});

describe("createApiClient.post", () => {
  it("POSTs a JSON body with the bearer token and returns the created resource", async () => {
    const response = new Response(JSON.stringify({ id: "inv-1", email: "a@b.co" }), {
      status: 201,
      headers: { "Content-Type": "application/json" },
    });
    const fetchMock = vi.fn().mockResolvedValue(response);
    const client = createApiClient("https://app.example", () => "tok", fetchMock);

    const result = await client.post<{ id: string; email: string }>(
      "/organizations/o1/invitations",
      { email: "a@b.co", role: "user" },
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "https://app.example/v1/organizations/o1/invitations",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ email: "a@b.co", role: "user" }),
        headers: expect.objectContaining({
          "Content-Type": "application/json",
          Authorization: "Bearer tok",
        }),
      }),
    );
    expect(result).toEqual({ id: "inv-1", email: "a@b.co" });
  });

  it("maps a 409 to a conflict ApiError (duplicate invitation)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ title: "Conflict" }, 409));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await expect(
      client.post("/organizations/o1/invitations", { email: "a@b.co" }),
    ).rejects.toMatchObject({ kind: "conflict", status: 409 });
  });
});

describe("createApiClient.del", () => {
  it("DELETEs the path with the bearer token and resolves on 204 No Content", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    const client = createApiClient("https://app.example", () => "tok", fetchMock);

    await expect(client.del("/organizations/o1/members/u1")).resolves.toBeUndefined();

    expect(fetchMock).toHaveBeenCalledWith(
      "https://app.example/v1/organizations/o1/members/u1",
      expect.objectContaining({
        method: "DELETE",
        headers: expect.objectContaining({ Authorization: "Bearer tok" }),
      }),
    );
  });

  it("maps a 409 to a conflict ApiError (last-admin guard)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ title: "Conflict" }, 409));
    const client = createApiClient("https://app.example", () => "t", fetchMock);

    await expect(client.del("/organizations/o1/members/u1")).rejects.toMatchObject({
      kind: "conflict",
      status: 409,
    });
  });
});
