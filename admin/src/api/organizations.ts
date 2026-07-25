import type { ApiClient, ETagged } from "./client";

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

// --- Organization management (view/edit) — NFR-ROL-2, FR-ONB-2, #73. -----------------------

/** Max lengths mirror the `Organization`/`OrganizationUpdate` schema + the server's own limits. */
export const ORG_NAME_MAX_LENGTH = 200;
export const ORG_ADDRESS_MAX_LENGTH = 500;

/**
 * The full organization record (`Organization` schema) the management screen views and edits.
 * `address` is nullable (`[string, "null"]`); `role` is the caller's own membership role and is
 * read-only. `id` is the path segment for the `PATCH /organizations/{orgId}` write.
 */
export interface Organization {
  readonly id: string;
  readonly name: string;
  readonly address: string | null;
  readonly role: MembershipRole;
  readonly created_at?: string;
  readonly updated_at?: string;
}

/** The mutable slice of an organization (`OrganizationUpdate` schema — at least one field). */
export interface OrganizationUpdate {
  readonly name?: string;
  readonly address?: string | null;
}

/**
 * Fetch the caller's own organization for the management screen, together with its `ETag`.
 *
 * Reading via `/organizations/me` (not `/organizations/{orgId}`) keeps the UI strictly scoped
 * to the caller's own admin org — the org id is resolved server-side from the caller's active
 * membership, never chosen client-side (FR-TEN-2). The returned `ETag` is the version stamp the
 * subsequent PATCH echoes back as `If-Match` for optimistic concurrency.
 */
export function getOrganization(client: ApiClient): Promise<ETagged<Organization>> {
  return client.getWithETag<Organization>("/organizations/me");
}

/**
 * Persist an edit of the caller's organization through `PATCH /organizations/{orgId}` with
 * optimistic concurrency: `etag` (from the prior GET) is sent as `If-Match`, so a stale write
 * — someone else changed the org in the meantime — is rejected server-side with a `409`
 * (surfaced as an `ApiError` of kind `conflict`). The server re-enforces admin-only + org-scope
 * regardless of the client (auth.md §5.3), and records the change in entity history (FR-HIS-1).
 */
export function updateOrganization(
  client: ApiClient,
  orgId: string,
  update: OrganizationUpdate,
  etag: string | null,
): Promise<ETagged<Organization>> {
  return client.patch<Organization>(`/organizations/${orgId}`, update, { ifMatch: etag });
}

/** The application admin role (NFR-ROL-1). */
export const ADMIN_ROLE = "admin";

export function isAdminRole(role: MembershipRole | undefined | null): boolean {
  return role === ADMIN_ROLE;
}
