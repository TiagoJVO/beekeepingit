import { describe, expect, it } from "vitest";
import { DEFAULT_INVITE_ROLE, INVITABLE_ROLES, validateInviteForm } from "./inviteForm";

describe("validateInviteForm", () => {
  it("flags an empty email as required", () => {
    expect(validateInviteForm({ email: "   ", role: "user" })).toEqual({ email: "required" });
  });

  it("flags a malformed email as invalid", () => {
    expect(validateInviteForm({ email: "not-an-email", role: "user" })).toEqual({
      email: "invalid",
    });
    expect(validateInviteForm({ email: "a@b", role: "user" })).toEqual({ email: "invalid" });
    expect(validateInviteForm({ email: "a b@c.co", role: "user" })).toEqual({ email: "invalid" });
  });

  it("accepts a well-formed email (trimming surrounding whitespace)", () => {
    expect(validateInviteForm({ email: "  ana@example.com  ", role: "admin" })).toEqual({});
  });
});

describe("invite role model (fixed admin/user — NFR-ROL-1)", () => {
  it("offers exactly the admin and user roles", () => {
    expect([...INVITABLE_ROLES].sort()).toEqual(["admin", "user"]);
  });

  it("defaults a new invitee to the least-privilege member role", () => {
    expect(DEFAULT_INVITE_ROLE).toBe("user");
  });
});
