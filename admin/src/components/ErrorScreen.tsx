import { useTranslation } from "react-i18next";

interface ErrorScreenProps {
  heading: string;
  message: string;
  onRetry?: () => void;
}

export function ErrorScreen({ heading, message, onRetry }: ErrorScreenProps) {
  const { t } = useTranslation();
  return (
    <main className="page">
      <div className="card stack" role="alert">
        <h1>{heading}</h1>
        <p>{message}</p>
        {onRetry && (
          <button type="button" className="btn btn-primary" onClick={onRetry}>
            {t("error.retry")}
          </button>
        )}
      </div>
    </main>
  );
}
