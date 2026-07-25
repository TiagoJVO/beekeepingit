import { useTranslation } from "react-i18next";
import type { AppConfig } from "../config/env";
import { MemberManagement } from "./MemberManagement";
import { OrganizationSettings } from "./OrganizationSettings";
import { QuotasSeam } from "./QuotasSeam";

interface AppShellProps {
  config: AppConfig;
  userName: string;
  orgName: string;
  /** The caller's own organization id, resolved server-side (used to scope member management). */
  orgId?: string;
  accountUrl?: string;
  onSignOut: () => void;
}

/**
 * The guarded landing shell shown only to admins (auth.md §5.3). It hosts the administrative
 * screens — organization management (view/edit name + address — #73) and member management
 * (view/invite/remove — #74) — each in its own card; further screens (roles) slot into the
 * same frame.
 */
export function AppShell({
  config,
  userName,
  orgName,
  orgId,
  accountUrl,
  onSignOut,
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
      <main className="page page-top">
        <div className="stack" style={{ maxWidth: "40rem", width: "100%" }}>
          <div className="card stack">
            <p>
              <span className="badge">{t("shell.roleBadge")}</span>
            </p>
            <p className="muted">{t("shell.signedInAs", { name: userName, org: orgName })}</p>
            <OrganizationSettings config={config} />
          </div>
          <div className="card stack">
            <MemberManagement config={config} orgId={orgId} />
          </div>
        </div>
      </main>
    </div>
  );
}
