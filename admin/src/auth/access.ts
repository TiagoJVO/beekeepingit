import type { ApiErrorKind } from "../api/client";
import type { MembershipRole } from "../api/organizations";
import { isAdminRole } from "../api/organizations";

// Pure decision logic for the admin-only guard (NFR-ROL-1). Kept free of React/async so
// every branch is exhaustively unit-testable. AdminGuard maps live auth + role-query state
// onto these inputs and renders the matching view.

export type AccessView =
  | { view: "loading"; reason: "auth" | "access" }
  | { view: "auth-error" }
  | { view: "login" }
  | { view: "access-error"; kind: "network" | "generic" }
  | { view: "denied"; reason: "not-admin" | "no-org" }
  | { view: "admin" };

export type RoleQueryStatus = "pending" | "error" | "success";

export interface AccessInputs {
  readonly authLoading: boolean;
  readonly authError: boolean;
  readonly isAuthenticated: boolean;
  readonly roleStatus: RoleQueryStatus;
  readonly role?: MembershipRole;
  readonly roleErrorKind?: ApiErrorKind;
}

/**
 * Decide what the guard should render. Order matters:
 *  1. auth still resolving → loading
 *  2. auth failed → auth-error
 *  3. not authenticated → login
 *  4. authenticated: resolve the caller's server-side membership role
 *     - pending → loading
 *     - 404 (no membership) → denied (no-org); other errors → access-error
 *     - admin → admin; anything else (e.g. `user`) → denied (not-admin)
 */
export function decideAccess(input: AccessInputs): AccessView {
  if (input.authLoading) {
    return { view: "loading", reason: "auth" };
  }
  if (input.authError) {
    return { view: "auth-error" };
  }
  if (!input.isAuthenticated) {
    return { view: "login" };
  }

  switch (input.roleStatus) {
    case "pending":
      return { view: "loading", reason: "access" };
    case "error":
      if (input.roleErrorKind === "not-found") {
        return { view: "denied", reason: "no-org" };
      }
      return {
        view: "access-error",
        kind: input.roleErrorKind === "network" ? "network" : "generic",
      };
    case "success":
      return isAdminRole(input.role) ? { view: "admin" } : { view: "denied", reason: "not-admin" };
  }
}
