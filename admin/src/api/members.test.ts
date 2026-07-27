import { describe, expect, it, vi } from "vitest";
import {
  changeMemberRole,
  createInvitation,
  listMembers,
  MEMBERS_PAGE_LIMIT,
  removeMember,
} from "./members";
import type { ApiClient } from "./client";

function mockClient(overrides: Partial<ApiClient> = {}): ApiClient {
  return {
    get: vi.fn(),
    getWithETag: vi.fn(),
    patch: vi.fn(),
    post: vi.fn(),
    del: vi.fn(),
    ...overrides,
  } satisfies ApiClient;
}

describe("listMembers", () => {
  it("GETs the first page with the page limit and no cursor", async () => {
    const get = vi.fn().mockResolvedValue({ data: [], page: { limit: MEMBERS_PAGE_LIMIT } });
    const client = mockClient({ get });

    await listMembers(client, "org-1");

    expect(get).toHaveBeenCalledWith(`/organizations/org-1/members?limit=${MEMBERS_PAGE_LIMIT}`);
  });

  it("passes the cursor for a subsequent page (keyset pagination)", async () => {
    const get = vi.fn().mockResolvedValue({ data: [], page: { limit: MEMBERS_PAGE_LIMIT } });
    const client = mockClient({ get });

    await listMembers(client, "org-1", "cursor-abc");

    expect(get).toHaveBeenCalledWith(
      `/organizations/org-1/members?limit=${MEMBERS_PAGE_LIMIT}&cursor=cursor-abc`,
    );
  });

  it("returns the parsed member list", async () => {
    const page = {
      data: [{ user_id: "u1", role: "admin", status: "active" }],
      page: { next_cursor: "next", limit: MEMBERS_PAGE_LIMIT },
    };
    const client = mockClient({ get: vi.fn().mockResolvedValue(page) });

    await expect(listMembers(client, "org-1")).resolves.toEqual(page);
  });
});

describe("createInvitation", () => {
  it("POSTs the invitation body (email + role) to the org's invitations endpoint", async () => {
    const post = vi.fn().mockResolvedValue({ id: "inv-1", email: "a@b.co", role: "user" });
    const client = mockClient({ post });

    const result = await createInvitation(client, "org-1", { email: "a@b.co", role: "user" });

    expect(post).toHaveBeenCalledWith("/organizations/org-1/invitations", {
      email: "a@b.co",
      role: "user",
    });
    expect(result).toMatchObject({ id: "inv-1", role: "user" });
  });

  it("sends the chosen admin role through unchanged (role picked at invite time)", async () => {
    const post = vi.fn().mockResolvedValue({ id: "inv-2", email: "c@d.co", role: "admin" });
    const client = mockClient({ post });

    await createInvitation(client, "org-1", { email: "c@d.co", role: "admin" });

    expect(post).toHaveBeenCalledWith("/organizations/org-1/invitations", {
      email: "c@d.co",
      role: "admin",
    });
  });
});

describe("removeMember", () => {
  it("DELETEs the member under the org, scoped by user id", async () => {
    const del = vi.fn().mockResolvedValue(undefined);
    const client = mockClient({ del });

    await removeMember(client, "org-1", "u9");

    expect(del).toHaveBeenCalledWith("/organizations/org-1/members/u9");
  });
});

describe("changeMemberRole", () => {
  it("PATCHes the member's role to the chosen value (fixed admin/user model)", async () => {
    const patch = vi
      .fn()
      .mockResolvedValue({ data: { user_id: "u9", role: "admin", status: "active" }, etag: null });
    const client = mockClient({ patch });

    await changeMemberRole(client, "org-1", "u9", "admin");

    // PATCH /organizations/{orgId}/members/{userId} with the MemberRoleUpdate body — no If-Match.
    expect(patch).toHaveBeenCalledWith("/organizations/org-1/members/u9", { role: "admin" });
  });

  it("returns the member's updated record, unwrapped from the ETag envelope", async () => {
    const updated = { user_id: "u9", role: "user", status: "active" };
    const patch = vi.fn().mockResolvedValue({ data: updated, etag: null });
    const client = mockClient({ patch });

    await expect(changeMemberRole(client, "org-1", "u9", "user")).resolves.toEqual(updated);
  });

  it("encodes id path segments (defense-in-depth against path injection)", async () => {
    const patch = vi
      .fn()
      .mockResolvedValue({ data: { user_id: "a/b", role: "user", status: "active" }, etag: null });
    const client = mockClient({ patch });

    await changeMemberRole(client, "org 1", "a/b", "user");

    expect(patch).toHaveBeenCalledWith("/organizations/org%201/members/a%2Fb", { role: "user" });
  });
});
