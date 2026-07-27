import { useTranslation } from "react-i18next";

interface ConfigErrorProps {
  missing: string[];
}

/** Shown when required VITE_* env vars are absent (parsed by readConfig). */
export function ConfigError({ missing }: ConfigErrorProps) {
  const { t } = useTranslation();
  return (
    <main className="page">
      <div className="card stack" role="alert">
        <h1>{t("config.heading")}</h1>
        <p>{t("config.body")}</p>
        <ul>
          {missing.map((name) => (
            <li key={name}>
              <code>{name}</code>
            </li>
          ))}
        </ul>
        <p className="muted">{t("config.seeExample")}</p>
      </div>
    </main>
  );
}
