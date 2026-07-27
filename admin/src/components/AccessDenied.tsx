import { useTranslation } from "react-i18next";

interface AccessDeniedProps {
  reason: "not-admin" | "no-org";
  onSignOut: () => void;
}

export function AccessDenied({ reason, onSignOut }: AccessDeniedProps) {
  const { t } = useTranslation();
  return (
    <main className="page">
      <div className="card stack" role="alert">
        <h1>{t("denied.heading")}</h1>
        <p>{reason === "no-org" ? t("denied.noOrg") : t("denied.body")}</p>
        <button type="button" className="btn btn-secondary" onClick={onSignOut}>
          {t("denied.signOut")}
        </button>
      </div>
    </main>
  );
}
