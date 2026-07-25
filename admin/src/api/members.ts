import type { ApiClient } from "./client";
import type { MembershipRole } from "./organizations";

// Mirrors the members/invitations slice of the `organizations` OpenAPI contract
// (contracts/openapi/organizations.openapi.yaml): the admin-only member roster
// (`GET .../members`), an email invitation (`POST .../invitations`), and member removal
// (`DELETE .../members/{userId}`). The server is authoritative on tenancy + admin-only
// access (auth.md §5.3) and on the last-admin guard (D-3) — this layer is a typed shim.

/** A member's lifecycle status within the organization (`Member.status`). */
export type MemberStatus = "active" | "invited" | "removed";

/**
 * A single organization member (`Member` schema). The contract exposes only the id, role and
 * status here — display names live behind the separate least-privilege `.../members/names`
 * roster (auth.md §5.3), which this admin screen does not consume.
 */
export interface Member {
  readonly user_id: string;
  readonly role: MembershipRole;
  readonly status: MemberStatus;
}

/** Cursor-pagination envelope metadata (`Page` schema — keyset, ADR-0003). */
export interface Page {
  /** Cursor for the next page, or null when there are no more items. */
  readonly next_cursor?: string | null;
  readonly limit: number;
}

/** A page of members (`MemberList` schema). */
export interface MemberList {
  readonly data: readonly Member[];
  readonly page: Page;
}

/** The two roles an invitee can be given at invite time (`Role` enum — fixed, NFR-ROL-1). */
export type InvitableRole = "admin" | "user";

/** New-invitation request body (`InvitationCreate` schema): email is required, role optional. */
export interface InvitationCreate {
  readonly email: string;
  readonly role?: InvitableRole;
}

/** A created/pending invitation (`Invitation` schema — the subset the UI needs). */
export interface Invitation {
  readonly id: string;
  readonly email: string;
  readonly role: MembershipRole;
  readonly status: "pending" | "accepted" | "expired" | "revoked";
}

/** Mirrors the server default page size (`LimitParam.default`); a page holds up to this many. */
export const MEMBERS_PAGE_LIMIT = 50;

function membersPath(orgId: string, cursor?: string | null): string {
  const params = new URLSearchParams({ limit: String(MEMBERS_PAGE_LIMIT) });
  if (cursor) params.set("cursor", cursor);
  // Encode the id path segment (defense-in-depth — ids are server-sourced today, but never
  // interpolate an untrusted value into a URL path raw); query params go via URLSearchParams.
  return `/organizations/${encodeURIComponent(orgId)}/members?${params.toString()}`;
}

/**
 * Fetch one page of the organization's members (`GET .../members`, admin-only, NFR-ROL-2).
 *
 * `cursor` is the opaque keyset cursor from a previous page's `page.next_cursor`; omit it for
 * the first page. The server re-enforces admin-only + org-scope regardless of the client
 * (auth.md §5.3): a `403` for a non-admin caller surfaces as an `ApiError` of kind `forbidden`.
 */
export function listMembers(
  client: ApiClient,
  orgId: string,
  cursor?: string | null,
): Promise<MemberList> {
  return client.get<MemberList>(membersPath(orgId, cursor));
}

/**
 * Invite a new member by email (`POST .../invitations`, FR-ONB-3, D-3). The invitee's role is
 * chosen at invite time from the fixed `admin`/`user` model (`InvitationCreate.role`, auth.md
 * §5.3). The invitation (and later acceptance) is recorded in entity history server-side
 * (FR-HIS-1). A malformed email is a `422`; a duplicate/pending invitation is a `409`.
 */
export function createInvitation(
  client: ApiClient,
  orgId: string,
  invite: InvitationCreate,
): Promise<Invitation> {
  return client.post<Invitation>(`/organizations/${encodeURIComponent(orgId)}/invitations`, invite);
}

/**
 * Remove a member (`DELETE .../members/{userId}`, FR-TEN-2, NFR-ROL-1). The server soft-removes
 * (`status` → `removed`) so the member loses org access on their next request (D-3), and records
 * the removal in entity history (FR-HIS-1). The **last-admin guard** rejects removing the org's
 * only remaining admin with a `409` (D-3) — surfaced as an `ApiError` of kind `conflict`; a user
 * who is not an active member is `404` (ADR-0002, never `403`).
 */
export function removeMember(client: ApiClient, orgId: string, userId: string): Promise<void> {
  return client.del(
    `/organizations/${encodeURIComponent(orgId)}/members/${encodeURIComponent(userId)}`,
  );
}
