import { useTranslation } from "react-i18next";

interface AppShellProps {
  userName: string;
  orgName: string;
  accountUrl?: string;
  onSignOut: () => void;
}

/**
 * The guarded landing shell shown only to admins. Real administrative screens (members,
 * roles, invitations — auth.md §5.3) land in follow-up stories; this is the authenticated,
 * admin-gated frame + placeholder they slot into.
 */
export function AppShell({ userName, orgName, accountUrl, onSignOut }: AppShellProps) {
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
      <main className="page">
        <div className="card stack">
          <p>
            <span className="badge">{t("shell.roleBadge")}</span>
          </p>
          <h1>{t("shell.welcome", { name: userName })}</h1>
          <p>{t("shell.org", { org: orgName })}</p>
          <p className="muted">{t("shell.placeholder")}</p>
        </div>
      </main>
    </div>
  );
}
