import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "react-oidc-context";
import { createApiClient } from "../api/client";
import { getMyOrganization } from "../api/organizations";
import type { MyOrganization } from "../api/organizations";
import type { AppConfig } from "../config/env";

/**
 * Fetch the caller's organization + membership role from the server (NFR-ROL-1). The role
 * is authoritative on the server and NOT a token claim (auth.md §3.4), so it is fetched via
 * an authenticated API call, never decoded from the access token. The bearer token is
 * attached by the API client on every request (NFR-SEC-1).
 */
export function useMembershipRole(config: AppConfig) {
  const auth = useAuth();
  const token = auth.user?.access_token ?? null;

  const client = useMemo(
    () => createApiClient(config.apiBaseUrl, () => token),
    [config.apiBaseUrl, token],
  );

  return useQuery<MyOrganization>({
    // Scope the cache to the authenticated subject so a role response can never be reused
    // across identities (full-page IdP redirects already discard the QueryClient today; this
    // hardens against any future in-app account switch).
    queryKey: ["my-organization", auth.user?.profile.sub ?? null],
    queryFn: () => getMyOrganization(client),
    enabled: auth.isAuthenticated,
    retry: false,
    staleTime: 60_000,
  });
}
