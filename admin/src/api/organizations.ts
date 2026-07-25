import type { ApiClient } from "./client";

// Mirrors the `organizations` OpenAPI contract (contracts/openapi/organizations.openapi.yaml):
// the caller's membership role is an open enum, resolved server-side per request from
// `organizations.memberships` — it is NOT a token claim (auth.md §3.4). Typed as a string
// union of the known values plus a fallback, honoring the "extensible set" convention.
export type MembershipRole = "admin" | "user" | (string & {});

/** `GET /v1/organizations/me` response (subset the admin app needs). */
export interface MyOrganization {
  readonly id: string;
  readonly name: string;
  /** The caller's own membership role in this organization (#172). */
  readonly role: MembershipRole;
}

/**
 * Fetch the caller's own organization, including their membership role.
 *
 * Resolves the org from the caller's active membership — no orgId needed. A 404 (mapped to
 * ApiError kind "not-found") means the caller has no active membership yet.
 */
export function getMyOrganization(client: ApiClient): Promise<MyOrganization> {
  return client.get<MyOrganization>("/organizations/me");
}

/** The application admin role (NFR-ROL-1). */
export const ADMIN_ROLE = "admin";

export function isAdminRole(role: MembershipRole | undefined | null): boolean {
  return role === ADMIN_ROLE;
}
