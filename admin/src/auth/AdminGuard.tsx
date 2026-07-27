import { useCallback, useState } from "react";
import { useAuth } from "react-oidc-context";
import { useTranslation } from "react-i18next";
import { ApiError } from "../api/client";
import type { AppConfig } from "../config/env";
import type { OrganizationSummary } from "../api/organizations";
import { useMembershipRole } from "../hooks/useMembershipRole";
import { useOrganizations } from "../hooks/useOrganizations";
import { decideAccess } from "./access";
import { decideOperatorGate } from "./operatorAccess";
import { Loading } from "../components/Loading";
import { LoginScreen } from "../components/LoginScreen";
import { AccessDenied } from "../components/AccessDenied";
import { ErrorScreen } from "../components/ErrorScreen";
import { AppShell } from "../components/AppShell";
import { OrganizationPicker } from "../components/OrganizationPicker";

interface AdminGuardProps {
  config: AppConfig;
}

/**
 * Gate the whole app behind (a) an authenticated OIDC session and (b) either the org-scoped
 * `admin` membership role (NFR-ROL-1/2, organization tier — #73/#74/#75) OR a verified platform
 * operator picking an organization to administer (NFR-ROL-2, D-32, EPIC-18 #463, #469).
 *
 * `decideAccess` (unchanged since #73) is evaluated first and owns every outcome it produces
 * EXCEPT one: "denied: no-org" (a `404` from `GET /organizations/me` — no active membership).
 * Only in that one case does the guard ask a second question — does `GET /organizations` (#467)
 * succeed for this caller? The app never reads the `platform_operator` token claim itself (it is
 * server-verified and admin-client-only, auth.md §3.4); a `200` here is the client-side signal
 * that it does, and the guard renders the organization picker (#469). A `403` means the caller is
 * genuinely neither an org member nor a platform operator — falls through to the exact same "no
 * organization" denial #73 always showed.
 *
 * This ordering — the operator gate is consulted ONLY from the pre-existing "denied: no-org"
 * branch, never in place of any other branch — is what keeps the organization-admin path (and
 * every other pre-#469 outcome) provably byte-for-byte unchanged.
 */
export function AdminGuard({ config }: AdminGuardProps) {
  const auth = useAuth();
  const { t } = useTranslation();
  const roleQuery = useMembershipRole(config);

  const onSignIn = useCallback(() => {
    void auth.signinRedirect();
  }, [auth]);

  const onSignOut = useCallback(() => {
    void auth.signoutRedirect();
  }, [auth]);

  const roleErrorKind = roleQuery.error instanceof ApiError ? roleQuery.error.kind : undefined;

  const decision = decideAccess({
    authLoading: auth.isLoading,
    authError: Boolean(auth.error),
    isAuthenticated: auth.isAuthenticated,
    roleStatus: roleQuery.status,
    role: roleQuery.data?.role,
    roleErrorKind,
  });

  const userName = auth.user?.profile.name ?? auth.user?.profile.preferred_username ?? "";

  // The operator gate is consulted ONLY when the organization-tier decision above is exactly
  // "denied: no-org" — every other outcome (admin, not-admin, loading, login, errors) renders
  // below completely unchanged from #73, and this hook's result is never read for them. `enabled`
  // being false the rest of the time means the request is never fired for an ordinary org admin.
  const noOrgMembership = decision.view === "denied" && decision.reason === "no-org";

  const [orgSearch, setOrgSearch] = useState("");
  const [selectedOrg, setSelectedOrg] = useState<OrganizationSummary | null>(null);

  const { query: organizationsQuery, organizations } = useOrganizations(config, {
    enabled: noOrgMembership,
    search: orgSearch,
  });

  const onSwitchOrganization = useCallback(() => {
    setSelectedOrg(null);
  }, []);

  if (!noOrgMembership) {
    // Byte-for-byte the pre-#469 switch over `decision.view` — nothing in this branch changed.
    switch (decision.view) {
      case "loading":
        return (
          <Loading
            message={
              decision.reason === "auth" ? t("loading.authenticating") : t("loading.checkingAccess")
            }
          />
        );
      case "auth-error":
        return (
          <ErrorScreen
            heading={t("error.authHeading")}
            message={auth.error?.message ?? t("error.generic")}
            onRetry={onSignIn}
          />
        );
      case "login":
        return <LoginScreen onSignIn={onSignIn} />;
      case "access-error":
        return (
          <ErrorScreen
            heading={t("error.accessHeading")}
            message={decision.kind === "network" ? t("error.network") : t("error.generic")}
            onRetry={() => void roleQuery.refetch()}
          />
        );
      case "denied":
        // Only ever "not-admin" here — "no-org" is routed to the operator gate below instead.
        return <AccessDenied reason={decision.reason} onSignOut={onSignOut} />;
      case "admin":
        return (
          <AppShell
            config={config}
            userName={userName}
            orgName={roleQuery.data?.name ?? ""}
            orgId={roleQuery.data?.id}
            accountUrl={config.accountUrl || undefined}
            onSignOut={onSignOut}
          />
        );
    }
  }

  // --- Platform-operator gate (#469) — reached only on "denied: no-org" above. -----------------
  const organizationsErrorKind =
    organizationsQuery.error instanceof ApiError ? organizationsQuery.error.kind : undefined;

  const operatorGate = decideOperatorGate({
    listStatus: organizationsQuery.status,
    listErrorKind: organizationsErrorKind,
  });

  switch (operatorGate.view) {
    case "checking":
      return <Loading message={t("loading.checkingAccess")} />;
    case "not-operator":
      // The exact pre-#469 "no organization" denial — same component, same reason, same copy.
      return <AccessDenied reason="no-org" onSignOut={onSignOut} />;
    case "error":
      return (
        <ErrorScreen
          heading={t("error.accessHeading")}
          message={operatorGate.kind === "network" ? t("error.network") : t("error.generic")}
          onRetry={() => void organizationsQuery.refetch()}
        />
      );
    case "operator":
      if (!selectedOrg) {
        return (
          <OrganizationPicker
            organizations={organizations}
            query={organizationsQuery}
            search={orgSearch}
            onSearchChange={setOrgSearch}
            onSelect={setSelectedOrg}
            userName={userName}
            onSignOut={onSignOut}
          />
        );
      }
      return (
        <AppShell
          config={config}
          userName={userName}
          orgName={selectedOrg.name}
          orgId={selectedOrg.id}
          accountUrl={config.accountUrl || undefined}
          onSignOut={onSignOut}
          operatorMode={{ onSwitchOrganization }}
        />
      );
  }
}
