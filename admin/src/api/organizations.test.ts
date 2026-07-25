import { describe, expect, it, vi } from "vitest";
import { getMyOrganization, isAdminRole } from "./organizations";
import type { ApiClient } from "./client";

describe("getMyOrganization", () => {
  it("fetches the caller's org + role from GET /organizations/me", async () => {
    const client: ApiClient = {
      get: vi.fn().mockResolvedValue({ id: "o1", name: "Org", role: "admin" }),
    };

    const org = await getMyOrganization(client);

    expect(client.get).toHaveBeenCalledWith("/organizations/me");
    expect(org).toEqual({ id: "o1", name: "Org", role: "admin" });
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
