import { useTranslation } from "react-i18next";
import type { InvitableRole } from "../api/members";

/**
 * A capability the two membership roles are (or are not) allowed to perform. `user`/`admin` mirror
 * the authoritative matrix in auth.md §5.3 exactly — this panel documents, it does not decide, and
 * must not invent capabilities the server doesn't actually gate.
 */
interface Capability {
  /** i18n key under `members.roleCapabilities.capabilities.*`. */
  readonly key: string;
  readonly user: boolean;
  readonly admin: boolean;
}

// The fixed two-role capability matrix (auth.md §5.3). The deferred quotas/rate-limit row (D-4) is
// intentionally omitted — it is not a live capability of the app yet, so listing it would misdescribe
// what the roles can do today.
const CAPABILITIES: readonly Capability[] = [
  { key: "data", user: true, admin: true },
  { key: "aiHistory", user: true, admin: true },
  { key: "members", user: false, admin: true },
  { key: "roles", user: false, admin: true },
  { key: "orgSettings", user: false, admin: true },
];

const ROLES: readonly InvitableRole[] = ["user", "admin"];

/**
 * An accessible, read-only reference of **what each role (`admin`/`user`) is allowed to do**
 * (NFR-ROL-1, auth.md §5.3) — the inspection half of roles management (#75). It renders the fixed
 * capability matrix as a real data table with a row header per capability and a column per role, so
 * the allowed/not-allowed marks are announced with their capability and role rather than read as bare
 * glyphs. Rendered collapsed behind a `<details>` so it is discoverable next to the roster without
 * crowding it.
 */
export function RoleCapabilities() {
  const { t } = useTranslation();

  function roleLabel(role: InvitableRole): string {
    return t(`members.roles.${role}`);
  }

  return (
    <details className="role-capabilities">
      <summary>{t("members.roleCapabilities.heading")}</summary>
      <p className="muted">{t("members.roleCapabilities.intro")}</p>
      <table className="data-table" aria-label={t("members.roleCapabilities.heading")}>
        <thead>
          <tr>
            <th scope="col">{t("members.roleCapabilities.columns.capability")}</th>
            {ROLES.map((role) => (
              <th scope="col" key={role}>
                {roleLabel(role)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {CAPABILITIES.map((capability) => (
            <tr key={capability.key}>
              <th scope="row">{t(`members.roleCapabilities.capabilities.${capability.key}`)}</th>
              {ROLES.map((role) => {
                const allowed = capability[role];
                return (
                  <td key={role} className="capability-cell">
                    <span aria-hidden="true">{allowed ? "✓" : "—"}</span>
                    <span className="visually-hidden">
                      {allowed
                        ? t("members.roleCapabilities.allowed")
                        : t("members.roleCapabilities.notAllowed")}
                    </span>
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </details>
  );
}
