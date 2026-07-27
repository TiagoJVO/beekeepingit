import { describe, expect, it } from "vitest";
import { isDirty, validateOrganizationForm } from "./organizationForm";
import { ORG_ADDRESS_MAX_LENGTH, ORG_NAME_MAX_LENGTH } from "../api/organizations";

describe("validateOrganizationForm", () => {
  it("accepts a valid name and address", () => {
    expect(validateOrganizationForm({ name: "Apiário Central", address: "Rua 1" })).toEqual({});
  });

  it("requires a non-empty (non-whitespace) name", () => {
    expect(validateOrganizationForm({ name: "   ", address: "" })).toEqual({ name: "required" });
  });

  it("flags a name over the maximum length", () => {
    const name = "a".repeat(ORG_NAME_MAX_LENGTH + 1);
    expect(validateOrganizationForm({ name, address: "" })).toEqual({ name: "too_long" });
  });

  it("allows an empty address (optional field)", () => {
    expect(validateOrganizationForm({ name: "Org", address: "" })).toEqual({});
  });

  it("flags an address over the maximum length", () => {
    const address = "a".repeat(ORG_ADDRESS_MAX_LENGTH + 1);
    expect(validateOrganizationForm({ name: "Org", address })).toEqual({ address: "too_long" });
  });
});

describe("isDirty", () => {
  it("is false when values equal the baseline", () => {
    expect(isDirty({ name: "Org", address: "A" }, { name: "Org", address: "A" })).toBe(false);
  });

  it("is true when any field differs", () => {
    expect(isDirty({ name: "Org 2", address: "A" }, { name: "Org", address: "A" })).toBe(true);
    expect(isDirty({ name: "Org", address: "B" }, { name: "Org", address: "A" })).toBe(true);
  });
});
