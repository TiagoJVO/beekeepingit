import { useTranslation } from "react-i18next";

interface LoginScreenProps {
  onSignIn: () => void;
}

export function LoginScreen({ onSignIn }: LoginScreenProps) {
  const { t } = useTranslation();
  return (
    <main className="page">
      <div className="card stack">
        <h1>{t("login.heading")}</h1>
        <p>{t("login.intro")}</p>
        <button type="button" className="btn btn-primary" onClick={onSignIn}>
          {t("login.signIn")}
        </button>
        <p className="muted">{t("login.accountNote")}</p>
      </div>
    </main>
  );
}
