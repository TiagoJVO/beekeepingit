import { useMemo } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { useAuth } from "react-oidc-context";
import { createApiClient } from "../api/client";
import { listOrganizations } from "../api/organizations";
import type { OrganizationSummary } from "../api/organizations";
import type { AppConfig } from "../config/env";

export interface UseOrganizationsOptions {
  /**
   * Gate the fetch behind the caller's context — this hook is only ever meaningful once
   * `GET /organizations/me` has already 404'd for the caller (`AdminGuard`'s operator gate, #469),
   * so the request is deliberately not fired for every user.
   */
  readonly enabled: boolean;
  /** Committed free-text search over organization name (empty string = no filter). */
  readonly search: string;
}

/**
 * List every organization on the platform (`GET /organizations`, #467/#469, platform-operator
 * only). Serves two purposes in the admin app: it is the client-side signal that detects operator
 * mode (a `200` here, only after `/organizations/me` 404'd, means the caller's verified token
 * carries `platform_operator` — see `src/auth/operatorAccess.ts`), and it drives the searchable,
 * paginated organization picker an operator selects an organization from.
 *
 * Follows the same `useInfiniteQuery` shape as `useMembers` (#74): pages accumulate behind a
 * "load more" affordance, keyed off the server's opaque `page.next_cursor` (ADR-0003 keyset
 * pagination). The committed `search` term is part of the query key so a changed search restarts
 * pagination from the first page rather than mixing pages fetched under a different filter.
 */
export function useOrganizations(config: AppConfig, options: UseOrganizationsOptions) {
  const auth = useAuth();
  const token = auth.user?.access_token ?? null;
  const subject = auth.user?.profile.sub ?? null;

  const client = useMemo(
    () => createApiClient(config.apiBaseUrl, () => token),
    [config.apiBaseUrl, token],
  );

  const queryKey = useMemo(
    () => ["organizations", subject, options.search] as const,
    [subject, options.search],
  );

  const query = useInfiniteQuery({
    queryKey,
    queryFn: ({ pageParam }) => listOrganizations(client, { cursor: pageParam, q: options.search }),
    enabled: auth.isAuthenticated && options.enabled,
    retry: false,
    staleTime: 60_000,
    initialPageParam: null as string | null,
    getNextPageParam: (lastPage) => lastPage.page.next_cursor ?? undefined,
  });

  const organizations: readonly OrganizationSummary[] = useMemo(
    () => query.data?.pages.flatMap((page) => page.data) ?? [],
    [query.data],
  );

  return { query, organizations };
}
