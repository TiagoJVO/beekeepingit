import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "react-oidc-context";
import { createApiClient } from "../api/client";
import type { ETagged } from "../api/client";
import { getOrganization, updateOrganization } from "../api/organizations";
import type { Organization, OrganizationUpdate } from "../api/organizations";
import type { AppConfig } from "../config/env";

/** Variables for an organization edit: the target org, the changed fields, and the version tag. */
export interface UpdateOrganizationVariables {
  readonly orgId: string;
  readonly update: OrganizationUpdate;
  readonly etag: string | null;
}

/**
 * Load the caller's organization (with its `ETag`) and expose a mutation to edit it (#73).
 *
 * The org is fetched from `GET /organizations/me` so the screen is strictly scoped to the
 * caller's own admin org (FR-TEN-2); the bearer token is attached by the API client on every
 * request (NFR-SEC-1). On a successful edit the query cache is replaced with the fresh record
 * and its new `ETag`, so an immediate follow-up edit uses the current version — no stale
 * `If-Match` and no manual refetch.
 */
export function useOrganization(config: AppConfig) {
  const auth = useAuth();
  const token = auth.user?.access_token ?? null;
  const subject = auth.user?.profile.sub ?? null;
  const queryClient = useQueryClient();

  const client = useMemo(
    () => createApiClient(config.apiBaseUrl, () => token),
    [config.apiBaseUrl, token],
  );

  const queryKey = useMemo(() => ["organization", subject] as const, [subject]);

  const query = useQuery<ETagged<Organization>>({
    queryKey,
    queryFn: () => getOrganization(client),
    enabled: auth.isAuthenticated,
    retry: false,
    staleTime: 60_000,
    // Never refetch this record out from under an in-progress edit: a background refresh would
    // swap the ETag (and the baseline the form diffs against) mid-edit. The screen adopts fresh
    // server state only on an explicit action — a successful save or the post-conflict reload.
    refetchOnReconnect: false,
    refetchOnWindowFocus: false,
  });

  const mutation = useMutation({
    mutationFn: (variables: UpdateOrganizationVariables) =>
      updateOrganization(client, variables.orgId, variables.update, variables.etag),
    onSuccess: (result) => {
      queryClient.setQueryData(queryKey, result);
    },
  });

  return { query, mutation };
}
