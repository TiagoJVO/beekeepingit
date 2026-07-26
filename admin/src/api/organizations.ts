import type { ApiClient, ETagged } from "./client";
import type { Page } from "./members";

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
  return client.patch<Organization>(`/organizations/${encodeURIComponent(orgId)}`, update, {
    ifMatch: etag,
  });
}

/** The application admin role (NFR-ROL-1). */
export const ADMIN_ROLE = "admin";

export function isAdminRole(role: MembershipRole | undefined | null): boolean {
  return role === ADMIN_ROLE;
}

// --- Platform-operator organization list + switcher (D-32, ADR-0021, #467/#469). -------------

/**
 * The minimal per-organization shape `GET /organizations` returns (`OrganizationSummary` schema,
 * #467, platform-operator only) — deliberately not the full `Organization` schema: no `address`,
 * no `created_by`, and no `role` (that field is the caller's own membership role in ONE org, #172
 * — meaningless for an operator enumerating every organization, who is a member of none of them).
 */
export interface OrganizationSummary {
  readonly id: string;
  readonly name: string;
  readonly member_count: number;
  readonly created_at?: string;
  readonly updated_at?: string;
}

/** A page of organizations (`OrganizationList` schema, #467). */
export interface OrganizationList {
  readonly data: readonly OrganizationSummary[];
  readonly page: Page;
}

/** Mirrors the server default page size (`LimitParam.default`); a page holds up to this many. */
export const ORGANIZATIONS_PAGE_LIMIT = 50;

function organizationsPath(params: { cursor?: string | null; q?: string }): string {
  const search = new URLSearchParams({ limit: String(ORGANIZATIONS_PAGE_LIMIT) });
  if (params.cursor) search.set("cursor", params.cursor);
  const trimmedQuery = params.q?.trim();
  if (trimmedQuery) search.set("q", trimmedQuery);
  return `/organizations?${search.toString()}`;
}

/**
 * List every organization on the platform (`GET /organizations`, #467, D-32) — platform-operator
 * only; every other caller is rejected with a `403` (there is no `{orgId}` in this path to hide
 * the existence of, so ADR-0002's usual 404-not-403 rule does not apply here).
 *
 * This call doubles as the admin app's client-side **operator-detection signal** (#469): the app
 * never reads the `platform_operator` token claim itself (it is a server-verified, admin-client-
 * only claim, auth.md §3.4) — instead, once `GET /organizations/me` has 404'd for the caller (no
 * active membership), the guard calls this. A `200` means the caller is a verified platform
 * operator (render the organization picker); a `403` means the caller genuinely has no
 * organization and is not an operator either (the pre-existing "no organization" denial, #73,
 * unchanged). `q` is a free-text, case-insensitive search over organization name.
 */
export function listOrganizations(
  client: ApiClient,
  params: { cursor?: string | null; q?: string } = {},
): Promise<OrganizationList> {
  return client.get<OrganizationList>(organizationsPath(params));
}

/**
 * Fetch a specific organization by id (`GET /organizations/{orgId}`), together with its `ETag`.
 *
 * Used by the organization-settings screen when a platform operator has selected an organization
 * to administer (#469) — unlike `getOrganization` (which always resolves the caller's **own** org
 * via `/me`), this targets an explicit id chosen from the organization list. The server
 * re-enforces the platform-operator-or-org-admin check regardless of the client (ADR-0021); a
 * caller who is neither gets `403`/`404` per the ordinary rules.
 */
export function getOrganizationById(
  client: ApiClient,
  orgId: string,
): Promise<ETagged<Organization>> {
  return client.getWithETag<Organization>(`/organizations/${encodeURIComponent(orgId)}`);
}
