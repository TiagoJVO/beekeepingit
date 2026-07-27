import { useState } from "react";
import type { FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { ApiError } from "../api/client";
import type { OrganizationSummary } from "../api/organizations";
import type { useOrganizations } from "../hooks/useOrganizations";

type OrganizationsQuery = ReturnType<typeof useOrganizations>["query"];

interface OrganizationPickerProps {
  readonly organizations: readonly OrganizationSummary[];
  readonly query: OrganizationsQuery;
  /** The currently committed search term (drives the query key in the parent). */
  readonly search: string;
  /** Commit a new search term — restarts pagination from the first page. */
  readonly onSearchChange: (value: string) => void;
  readonly onSelect: (org: OrganizationSummary) => void;
  readonly userName: string;
  readonly onSignOut: () => void;
}

/**
 * The platform-operator landing screen (#469, D-32): a searchable, paginated list of every
 * organization (`GET /organizations`, #467) an operator picks one from to administer.
 *
 * Reached only once `GET /organizations/me` has 404'd for the caller AND `GET /organizations` has
 * succeeded (the operator-detection signal, `src/auth/operatorAccess.ts`) — an organization-tier
 * admin never sees this screen (NFR-ROL-2).
 */
export function OrganizationPicker({
  organizations,
  query,
  search,
  onSearchChange,
  onSelect,
  userName,
  onSignOut,
}: OrganizationPickerProps) {
  const { t } = useTranslation();
  // Local, uncommitted input text — search only refetches on explicit submit (Enter / the Search
  // button), not on every keystroke, so behavior stays predictable and easy to test.
  const [searchInput, setSearchInput] = useState(search);

  function handleSearchSubmit(event: FormEvent<HTMLFormElement>): void {
    event.preventDefault();
    onSearchChange(searchInput.trim());
  }

  const errorKind = query.error instanceof ApiError ? query.error.kind : undefined;

  return (
    <div>
      <header className="topbar">
        <strong>{t("app.title")}</strong>
        <nav aria-label={t("app.title")} className="nav-actions">
          <button type="button" className="btn btn-secondary" onClick={onSignOut}>
            {t("app.signOut")}
          </button>
        </nav>
      </header>
      <main className="page page-top">
        <div className="stack" style={{ maxWidth: "40rem", width: "100%" }}>
          <div className="card stack" aria-labelledby="org-picker-heading">
            <h1 id="org-picker-heading">{t("orgPicker.heading")}</h1>
            <p className="muted">{t("orgPicker.intro", { name: userName })}</p>

            <form className="stack" onSubmit={handleSearchSubmit} role="search">
              <div className="field">
                <label htmlFor="org-search">{t("orgPicker.searchLabel")}</label>
                <input
                  id="org-search"
                  name="q"
                  type="search"
                  value={searchInput}
                  onChange={(e) => setSearchInput(e.target.value)}
                />
              </div>
              <div className="nav-actions">
                <button type="submit" className="btn btn-secondary">
                  {t("orgPicker.search")}
                </button>
              </div>
            </form>

            {query.isLoading ? (
              <p className="muted" role="status">
                {t("orgPicker.loading")}
              </p>
            ) : query.isError ? (
              <div className="stack" role="alert">
                <p>{errorKind === "network" ? t("error.network") : t("orgPicker.loadFailed")}</p>
                <button
                  type="button"
                  className="btn btn-secondary"
                  onClick={() => void query.refetch()}
                >
                  {t("error.retry")}
                </button>
              </div>
            ) : organizations.length === 0 ? (
              <p className="muted">{t("orgPicker.empty")}</p>
            ) : (
              <ul className="org-list" aria-label={t("orgPicker.listLabel")}>
                {organizations.map((org) => (
                  <li key={org.id}>
                    <button
                      type="button"
                      className="btn btn-secondary org-list-item"
                      onClick={() => onSelect(org)}
                    >
                      <span className="org-list-name">{org.name}</span>
                      <span className="muted">
                        {t("orgPicker.memberCount", { count: org.member_count })}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}

            {query.hasNextPage && (
              <div className="nav-actions">
                <button
                  type="button"
                  className="btn btn-secondary"
                  onClick={() => void query.fetchNextPage()}
                  disabled={query.isFetchingNextPage}
                >
                  {query.isFetchingNextPage ? t("orgPicker.loadingMore") : t("orgPicker.loadMore")}
                </button>
              </div>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}
