import { describe, expect, it } from "vitest";
import { decideOperatorGate } from "./operatorAccess";
import type { OperatorGateInputs } from "./operatorAccess";

const base: OperatorGateInputs = {
  listStatus: "pending",
};

describe("decideOperatorGate", () => {
  it("shows a checking view while GET /organizations is in flight", () => {
    expect(decideOperatorGate({ ...base, listStatus: "pending" })).toEqual({ view: "checking" });
  });

  it("treats a 403 (forbidden) as NOT a platform operator", () => {
    expect(
      decideOperatorGate({ ...base, listStatus: "error", listErrorKind: "forbidden" }),
    ).toEqual({ view: "not-operator" });
  });

  it("surfaces a network error distinctly", () => {
    expect(decideOperatorGate({ ...base, listStatus: "error", listErrorKind: "network" })).toEqual({
      view: "error",
      kind: "network",
    });
  });

  it("maps any other error to a generic error", () => {
    expect(decideOperatorGate({ ...base, listStatus: "error", listErrorKind: "http" })).toEqual({
      view: "error",
      kind: "generic",
    });
  });

  it("maps an undefined error kind to a generic error", () => {
    expect(decideOperatorGate({ ...base, listStatus: "error" })).toEqual({
      view: "error",
      kind: "generic",
    });
  });

  it("ALLOWS a verified platform operator on success", () => {
    expect(decideOperatorGate({ ...base, listStatus: "success" })).toEqual({ view: "operator" });
  });
});
