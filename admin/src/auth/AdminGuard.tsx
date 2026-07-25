import { useCallback } from "react";
import { useAuth } from "react-oidc-context";
import { useTranslation } from "react-i18next";
import { ApiError } from "../api/client";
import type { AppConfig } from "../config/env";
import { useMembershipRole } from "../hooks/useMembershipRole";
import { decideAccess } from "./access";
import { Loading } from "../components/Loading";
import { LoginScreen } from "../components/LoginScreen";
import { AccessDenied } from "../components/AccessDenied";
import { ErrorScreen } from "../components/ErrorScreen";
import { AppShell } from "../components/AppShell";

interface AdminGuardProps {
  config: AppConfig;
}

/**
 * Gate the whole app behind (a) an authenticated OIDC session and (b) the org-scoped
 * `admin` membership role (NFR-ROL-1/2). Non-admins get a clear "admin access required"
 * message; unauthenticated users get the login screen. The role decision is fully derived
 * from server state (auth.md §3.4/§5.3) — no client-side role trust.
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
      return <AccessDenied reason={decision.reason} onSignOut={onSignOut} />;
    case "admin":
      return (
        <AppShell
          config={config}
          userName={auth.user?.profile.name ?? auth.user?.profile.preferred_username ?? ""}
          orgName={roleQuery.data?.name ?? ""}
          orgId={roleQuery.data?.id}
          accountUrl={config.accountUrl || undefined}
          onSignOut={onSignOut}
        />
      );
  }
}
