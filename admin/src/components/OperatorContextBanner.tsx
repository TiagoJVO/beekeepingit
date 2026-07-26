import { useTranslation } from "react-i18next";

interface OperatorContextBannerProps {
  readonly orgName: string;
  readonly onSwitchOrganization: () => void;
}

/**
 * Persistent, safety-critical indicator (#469, D-32): visible on every screen while a platform
 * operator is administering an organization they are not a member of, so a destructive action
 * (edit settings, remove a member, change a role) is never taken against the wrong organization
 * by accident.
 *
 * Deliberately **not** colour-only (WCAG 1.4.1) — a decorative icon (`aria-hidden`) plus explicit
 * text naming the organization carries the meaning. `role="status"` makes it an assistive-tech
 * live region so it is announced whenever it (re)mounts, e.g. after switching organizations, not
 * just on first navigation into operator mode.
 */
export function OperatorContextBanner({
  orgName,
  onSwitchOrganization,
}: OperatorContextBannerProps) {
  const { t } = useTranslation();
  return (
    <div className="operator-banner" role="status" aria-atomic="true">
      <span className="operator-banner-icon" aria-hidden="true">
        ⚠
      </span>
      <p>{t("operatorBanner.message", { org: orgName })}</p>
      <button type="button" className="btn btn-secondary" onClick={onSwitchOrganization}>
        {t("operatorBanner.switch")}
      </button>
    </div>
  );
}
