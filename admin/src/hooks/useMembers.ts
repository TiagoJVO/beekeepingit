import { useMemo } from "react";
import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "react-oidc-context";
import { createApiClient } from "../api/client";
import { createInvitation, listMembers, removeMember } from "../api/members";
import type { InvitationCreate, Member, MemberList } from "../api/members";
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

  const query = useInfiniteQuery<MemberList>({
    queryKey,
    queryFn: ({ pageParam }) => listMembers(client, orgId as string, pageParam as string | null),
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

  const invalidateMembers = () => queryClient.invalidateQueries({ queryKey });

  const inviteMutation = useMutation({
    mutationFn: (variables: InviteMemberVariables) =>
      createInvitation(client, variables.orgId, variables.invite),
    onSuccess: () => void invalidateMembers(),
  });

  const removeMutation = useMutation({
    mutationFn: (variables: RemoveMemberVariables) =>
      removeMember(client, variables.orgId, variables.userId),
    onSuccess: () => void invalidateMembers(),
  });

  return { query, members, inviteMutation, removeMutation };
}
