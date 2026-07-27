import { useTranslation } from "react-i18next";

/**
 * INERT placeholder seam for quota & rate-limit management.
 *
 * This is ONLY the navigation seam that the real screens will slot into — there is NO quota
 * or rate-limit logic here and NOTHING is enforced against users. Quotas/rate-limits are
 * DEFERRED out of v1 (D-4); this preserves just the design/mechanism boundary (NFR-RL-1) in
 * the admin app that owns that management surface (NFR-ROL-2).
 *
 * The deferred work is tracked under **EPIC-91 — Rate Limiting & Quotas**; when it is picked
 * up, the real management screen replaces this stub.
 *
 * Kept hidden: `AppShell` only mounts this behind the default-off `VITE_FEATURE_QUOTAS_SEAM`
 * flag (see config/env.ts), so end users never see it in v1. When surfaced in a dev/flagged
 * state it renders as a clearly-labelled, disabled "coming later" entry (accessible name
 * spells out that it is unavailable), so it stays visibly inert.
 */
export function QuotasSeam() {
  const { t } = useTranslation();
  return (
    <button type="button" className="btn btn-secondary" disabled aria-disabled="true">
      {t("quotasSeam.navLabel")}
    </button>
  );
}
