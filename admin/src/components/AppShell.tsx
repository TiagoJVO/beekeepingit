import { useTranslation } from "react-i18next";
import type { AppConfig } from "../config/env";
import { OrganizationSettings } from "./OrganizationSettings";

interface AppShellProps {
  config: AppConfig;
  userName: string;
  orgName: string;
  accountUrl?: string;
  onSignOut: () => void;
}

/**
 * The guarded landing shell shown only to admins (auth.md §5.3). Its first administrative
 * screen is organization management (view/edit name + address — #73); further screens
 * (members, roles, invitations) land in follow-up stories and slot into the same frame.
 */
export function AppShell({ config, userName, orgName, accountUrl, onSignOut }: AppShellProps) {
  const { t } = useTranslation();
  return (
    <div>
      <header className="topbar">
        <strong>{t("app.title")}</strong>
        <nav aria-label={t("app.title")} className="nav-actions">
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
        <div className="card stack" style={{ maxWidth: "40rem" }}>
          <p>
            <span className="badge">{t("shell.roleBadge")}</span>
          </p>
          <p className="muted">{t("shell.signedInAs", { name: userName, org: orgName })}</p>
          <OrganizationSettings config={config} />
        </div>
      </main>
    </div>
  );
}
