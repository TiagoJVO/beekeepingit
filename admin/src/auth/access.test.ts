import { describe, expect, it } from "vitest";
import { decideAccess } from "./access";
import type { AccessInputs } from "./access";

const base: AccessInputs = {
  authLoading: false,
  authError: false,
  isAuthenticated: false,
  roleStatus: "pending",
};

describe("decideAccess", () => {
  it("shows a loading view while auth is resolving", () => {
    expect(decideAccess({ ...base, authLoading: true })).toEqual({
      view: "loading",
      reason: "auth",
    });
  });

  it("shows an auth error when the OIDC flow failed", () => {
    expect(decideAccess({ ...base, authError: true })).toEqual({ view: "auth-error" });
  });

  it("shows the login screen when unauthenticated", () => {
    expect(decideAccess({ ...base, isAuthenticated: false })).toEqual({ view: "login" });
  });

  it("shows a loading view while the membership role is being fetched", () => {
    expect(decideAccess({ ...base, isAuthenticated: true, roleStatus: "pending" })).toEqual({
      view: "loading",
      reason: "access",
    });
  });

  it("ALLOWS an authenticated admin", () => {
    expect(
      decideAccess({ ...base, isAuthenticated: true, roleStatus: "success", role: "admin" }),
    ).toEqual({ view: "admin" });
  });

  it("DENIES an authenticated non-admin (user role)", () => {
    expect(
      decideAccess({ ...base, isAuthenticated: true, roleStatus: "success", role: "user" }),
    ).toEqual({ view: "denied", reason: "not-admin" });
  });

  it("DENIES an unknown/future role that is not admin", () => {
    expect(
      decideAccess({ ...base, isAuthenticated: true, roleStatus: "success", role: "viewer" }),
    ).toEqual({ view: "denied", reason: "not-admin" });
  });

  it("denies with a no-org reason on a 404 (no active membership)", () => {
    expect(
      decideAccess({
        ...base,
        isAuthenticated: true,
        roleStatus: "error",
        roleErrorKind: "not-found",
      }),
    ).toEqual({ view: "denied", reason: "no-org" });
  });

  it("surfaces a network access error distinctly", () => {
    expect(
      decideAccess({
        ...base,
        isAuthenticated: true,
        roleStatus: "error",
        roleErrorKind: "network",
      }),
    ).toEqual({ view: "access-error", kind: "network" });
  });

  it("maps an unauthorized/other role error to a generic access error", () => {
    expect(
      decideAccess({
        ...base,
        isAuthenticated: true,
        roleStatus: "error",
        roleErrorKind: "unauthorized",
      }),
    ).toEqual({ view: "access-error", kind: "generic" });
  });
});
