import { useTranslation } from "react-i18next";
import type { AppConfig } from "../config/env";
import { MemberManagement } from "./MemberManagement";
import { OperatorContextBanner } from "./OperatorContextBanner";
import { OrganizationSettings } from "./OrganizationSettings";
import { QuotasSeam } from "./QuotasSeam";

/**
 * Present only when a platform operator is administering an organization they are not a member
 * of (#469, D-32) — drives the persistent operator-context banner AND switches the org-settings
 * screen from "my organization" (`/organizations/me`) onto the explicit `orgId` prop
 * (`/organizations/{orgId}`). Absent for the unchanged organization-admin path.
 */
export interface OperatorModeContext {
  readonly onSwitchOrganization: () => void;
}

interface AppShellProps {
  config: AppConfig;
  userName: string;
  orgName: string;
  /** The organization id being administered — the caller's own org, or an operator's pick. */
  orgId?: string;
  accountUrl?: string;
  onSignOut: () => void;
  operatorMode?: OperatorModeContext;
}

/**
 * The guarded landing shell shown only to admins (auth.md §5.3) or, once selected, to a platform
 * operator acting on an organization (D-32, #469). It hosts the administrative screens —
 * organization management (view/edit name + address — #73) and member management
 * (view/invite/remove — #74) — each in its own card; further screens (roles) slot into the
 * same frame. When `operatorMode` is present, a persistent banner names the organization being
 * administered and the org-settings screen reads/writes it directly via `orgId` instead of "my
 * organization" — the default (no `operatorMode`) path is unchanged from #73/#74/#75.
 */
export function AppShell({
  config,
  userName,
  orgName,
  orgId,
  accountUrl,
  onSignOut,
  operatorMode,
}: AppShellProps) {
  const { t } = useTranslation();
  return (
    <div>
      <header className="topbar">
        <strong>{t("app.title")}</strong>
        <nav aria-label={t("app.title")} className="nav-actions">
          {/* Deferred seam — inert unless explicitly flagged on (D-4 / EPIC-91). */}
          {config.quotasSeamEnabled && <QuotasSeam />}
          {accountUrl && (
            <a
              className="btn btn-secondary"
              href={accountUrl}
              target="_blank"
              rel="noopener noreferrer"
            >
              {t("app.manageAccount")}
            </a>
          )}
          <button type="button" className="btn btn-secondary" onClick={onSignOut}>
            {t("app.signOut")}
          </button>
        </nav>
      </header>
      {operatorMode && (
        <OperatorContextBanner
          orgName={orgName}
          onSwitchOrganization={operatorMode.onSwitchOrganization}
        />
      )}
      <main className="page page-top">
        <div className="stack" style={{ maxWidth: "40rem", width: "100%" }}>
          <div className="card stack">
            <p>
              <span className="badge">{t("shell.roleBadge")}</span>
            </p>
            <p className="muted">{t("shell.signedInAs", { name: userName, org: orgName })}</p>
            <OrganizationSettings config={config} orgId={operatorMode ? orgId : undefined} />
          </div>
          <div className="card stack">
            <MemberManagement config={config} orgId={orgId} />
          </div>
        </div>
      </main>
    </div>
  );
}
