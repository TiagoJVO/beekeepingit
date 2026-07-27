import type { ApiErrorKind } from "../api/client";

// Pure decision logic for the platform-operator gate (#469, D-32). Kept free of React/async, like
// `decideAccess` (access.ts), so every branch is exhaustively unit-testable.
//
// This is consulted from EXACTLY one place in `AdminGuard`: the pre-existing "denied: no-org"
// outcome of `decideAccess` (a 404 from `GET /organizations/me` — no active membership). It is
// never consulted for any other `decideAccess` outcome (admin, not-admin, loading, login, errors),
// which is what keeps the organization-admin path provably unchanged (#73/#74/#75).

export type OperatorGateStatus = "pending" | "error" | "success";

export type OperatorGateView =
  | { view: "checking" }
  | { view: "not-operator" }
  | { view: "error"; kind: "network" | "generic" }
  | { view: "operator" };

export interface OperatorGateInputs {
  readonly listStatus: OperatorGateStatus;
  readonly listErrorKind?: ApiErrorKind;
}

/**
 * Decide what the guard should render once the caller has no active organization membership,
 * based on whether `GET /organizations` (#467) succeeds for them:
 *  - pending → checking (loading)
 *  - `403` (forbidden) → not-operator — the caller genuinely has no organization and is not a
 *    platform operator either; falls through to the pre-existing "no organization" denial.
 *  - any other error → error (retryable)
 *  - `200` → operator — the caller's verified token carries `platform_operator` (server-checked,
 *    ADR-0021); render the organization picker/switcher.
 */
export function decideOperatorGate(input: OperatorGateInputs): OperatorGateView {
  switch (input.listStatus) {
    case "pending":
      return { view: "checking" };
    case "error":
      if (input.listErrorKind === "forbidden") {
        return { view: "not-operator" };
      }
      return { view: "error", kind: input.listErrorKind === "network" ? "network" : "generic" };
    case "success":
      return { view: "operator" };
  }
}
