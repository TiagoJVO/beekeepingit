import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "react-oidc-context";
import { createApiClient } from "../api/client";
import type { ETagged } from "../api/client";
import { getOrganization, getOrganizationById, updateOrganization } from "../api/organizations";
import type { Organization, OrganizationUpdate } from "../api/organizations";
import type { AppConfig } from "../config/env";

/** Variables for an organization edit: the target org, the changed fields, and the version tag. */
export interface UpdateOrganizationVariables {
  readonly orgId: string;
  readonly update: OrganizationUpdate;
  readonly etag: string | null;
}

/**
 * Load an organization (with its `ETag`) and expose a mutation to edit it (#73, #469).
 *
 * By default (no `orgId`) the org is fetched from `GET /organizations/me` so the screen is
 * strictly scoped to the caller's own admin org (FR-TEN-2) — this is the unchanged
 * organization-admin path. When an explicit `orgId` is supplied, a platform operator has selected
 * an organization from the list to administer (#469): the query instead targets that organization
 * directly via `GET /organizations/{orgId}`. This is never inferred from anything on the fetched
 * record itself — the server reports `role: "admin"` for both a real org admin and an operator
 * acting through the platform-operator carve-out (ADR-0021 Consequences), so `role` is not a safe
 * client-side signal to branch on; the caller of this hook already knows which mode it is in.
 *
 * The bearer token is attached by the API client on every request (NFR-SEC-1). On a successful
 * edit the query cache is replaced with the fresh record and its new `ETag`, so an immediate
 * follow-up edit uses the current version — no stale `If-Match` and no manual refetch.
 */
export function useOrganization(config: AppConfig, orgId?: string) {
  const auth = useAuth();
  const token = auth.user?.access_token ?? null;
  const subject = auth.user?.profile.sub ?? null;
  const queryClient = useQueryClient();

  const client = useMemo(
    () => createApiClient(config.apiBaseUrl, () => token),
    [config.apiBaseUrl, token],
  );

  // Unchanged key/fetch for the default (no orgId) case — an explicit orgId is a distinct cache
  // entry so it can never collide with, or be confused for, the caller's own "my org" record.
  const queryKey = useMemo(
    () =>
      orgId ? (["organization", subject, orgId] as const) : (["organization", subject] as const),
    [subject, orgId],
  );

  const query = useQuery<ETagged<Organization>>({
    queryKey,
    queryFn: () => (orgId ? getOrganizationById(client, orgId) : getOrganization(client)),
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
