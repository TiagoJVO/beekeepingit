import { describe, expect, it, vi } from "vitest";
import {
  getMyOrganization,
  getOrganization,
  isAdminRole,
  updateOrganization,
} from "./organizations";
import type { ApiClient } from "./client";

describe("getMyOrganization", () => {
  it("fetches the caller's org + role from GET /organizations/me", async () => {
    const client = {
      get: vi.fn().mockResolvedValue({ id: "o1", name: "Org", role: "admin" }),
      getWithETag: vi.fn(),
      patch: vi.fn(),
    } satisfies ApiClient;

    const org = await getMyOrganization(client);

    expect(client.get).toHaveBeenCalledWith("/organizations/me");
    expect(org).toEqual({ id: "o1", name: "Org", role: "admin" });
  });
});

describe("getOrganization", () => {
  it("reads the caller's own org with its ETag from GET /organizations/me (FR-TEN-2)", async () => {
    const client = {
      get: vi.fn(),
      getWithETag: vi.fn().mockResolvedValue({
        data: { id: "o1", name: "Org", address: null, role: "admin" },
        etag: '"v1"',
      }),
      patch: vi.fn(),
    } satisfies ApiClient;

    const result = await getOrganization(client);

    expect(client.getWithETag).toHaveBeenCalledWith("/organizations/me");
    expect(result.etag).toBe('"v1"');
    expect(result.data).toMatchObject({ id: "o1", address: null });
  });
});

describe("updateOrganization", () => {
  it("PATCHes /organizations/{orgId} with the fields and the ETag as If-Match", async () => {
    const client = {
      get: vi.fn(),
      getWithETag: vi.fn(),
      patch: vi.fn().mockResolvedValue({
        data: { id: "o1", name: "New", address: "Addr", role: "admin" },
        etag: '"v2"',
      }),
    } satisfies ApiClient;

    const result = await updateOrganization(client, "o1", { name: "New", address: "Addr" }, '"v1"');

    expect(client.patch).toHaveBeenCalledWith(
      "/organizations/o1",
      { name: "New", address: "Addr" },
      { ifMatch: '"v1"' },
    );
    expect(result.etag).toBe('"v2"');
  });
});

describe("isAdminRole", () => {
  it("is true only for the admin role", () => {
    expect(isAdminRole("admin")).toBe(true);
    expect(isAdminRole("user")).toBe(false);
    expect(isAdminRole("viewer")).toBe(false);
    expect(isAdminRole(undefined)).toBe(false);
    expect(isAdminRole(null)).toBe(false);
  });
});
