import { useMemo } from "react";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "react-oidc-context";
import { createApiClient } from "../api/client";
import { changeMemberRole, createInvitation, listMembers, removeMember } from "../api/members";
import type { InvitableRole, InvitationCreate, Member } from "../api/members";
import type { AppConfig } from "../config/env";

/** Variables for an invite: the target org and the new-invitation body (email + role). */
export interface InviteMemberVariables {
  readonly orgId: string;
  readonly invite: InvitationCreate;
}

/** Variables for a removal: the target org and the member's user id. */
export interface RemoveMemberVariables {
  readonly orgId: string;
  readonly userId: string;
}

/** Variables for a role change: the target org, the member's user id, and the new role. */
export interface ChangeMemberRoleVariables {
  readonly orgId: string;
  readonly userId: string;
  readonly role: InvitableRole;
}

/**
 * Load the caller's organization members (cursor-paginated) and expose invite + remove
 * mutations (#74). The org is always the caller's own admin org (FR-TEN-2); the bearer token
 * is attached by the API client on every request (NFR-SEC-1). The member list is fetched with
 * `useInfiniteQuery` so successive pages accumulate behind a "load more" affordance, keyed off
 * the server's opaque `page.next_cursor` (ADR-0003 keyset pagination).
 *
 * After a successful invite or remove the members query is invalidated so the roster re-reads
 * fresh server state — the server remains authoritative (last-admin guard, soft-remove: D-3).
 */
export function useMembers(config: AppConfig, orgId: string | undefined) {
  const auth = useAuth();
  const token = auth.user?.access_token ?? null;
  const subject = auth.user?.profile.sub ?? null;
  const queryClient = useQueryClient();

  const client = useMemo(
    () => createApiClient(config.apiBaseUrl, () => token),
    [config.apiBaseUrl, token],
  );

  const queryKey = useMemo(() => ["members", subject, orgId] as const, [subject, orgId]);

  // Let TanStack infer the page-param type from `initialPageParam`/`getNextPageParam` (so
  // `pageParam` is `string | null` with no cast), and narrow `orgId` with a runtime guard rather
  // than asserting it — the guard is co-located with the fetch, so it cannot drift from `enabled`.
  const query = useInfiniteQuery({
    queryKey,
    queryFn: ({ pageParam }) => {
      if (!orgId) return Promise.reject(new Error("useMembers: orgId is required"));
      return listMembers(client, orgId, pageParam);
    },
    enabled: auth.isAuthenticated && Boolean(orgId),
    retry: false,
    staleTime: 60_000,
    initialPageParam: null as string | null,
    getNextPageParam: (lastPage) => lastPage.page.next_cursor ?? undefined,
  });

  // Flatten the accumulated pages into a single immutable roster for rendering.
  const members: readonly Member[] = useMemo(
    () => query.data?.pages.flatMap((page) => page.data) ?? [],
    [query.data],
  );

  // Return the invalidation promise so `mutateAsync` only settles once the roster refetch has
  // been kicked off — keeps the success UI in step with the refreshed table (v5 idiom).
  const invalidateMembers = () => queryClient.invalidateQueries({ queryKey });

  const inviteMutation = useMutation({
    mutationFn: (variables: InviteMemberVariables) =>
      createInvitation(client, variables.orgId, variables.invite),
    onSuccess: () => invalidateMembers(),
  });

  const removeMutation = useMutation({
    mutationFn: (variables: RemoveMemberVariables) =>
      removeMember(client, variables.orgId, variables.userId),
    onSuccess: () => invalidateMembers(),
  });

  // Change a member's role (#75). The server is authoritative — it enforces the new role on the
  // target's next request and rejects demoting the last admin with a 409 (D-3) — so on success we
  // just invalidate the roster to reflect the updated role rather than mutating cache in place.
  const changeRoleMutation = useMutation({
    mutationFn: (variables: ChangeMemberRoleVariables) =>
      changeMemberRole(client, variables.orgId, variables.userId, variables.role),
    onSuccess: () => invalidateMembers(),
  });

  return { query, members, inviteMutation, removeMutation, changeRoleMutation };
}
