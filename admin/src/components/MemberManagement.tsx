import { useEffect, useRef, useState } from "react";
import type { FormEvent, KeyboardEvent } from "react";
import { useTranslation } from "react-i18next";
import { ApiError } from "../api/client";
import type { InvitableRole, Member } from "../api/members";
import type { AppConfig } from "../config/env";
import { useMembers } from "../hooks/useMembers";
import {
  DEFAULT_INVITE_ROLE,
  INVITABLE_ROLES,
  isInvitableRole,
  validateInviteForm,
} from "./inviteForm";

interface MemberManagementProps {
  config: AppConfig;
  /** The caller's own organization id (resolved server-side via `/organizations/me`). */
  orgId: string | undefined;
}

type InviteStatus = "idle" | "inviting" | "invited";

/**
 * View, invite and remove the caller's organization members — the admin member-management
 * screen (NFR-ROL-2, FR-ONB-3, FR-TEN-2, D-3, #74). It reads the paginated roster
 * (`GET .../members`), invites by email with a chosen role (`POST .../invitations`), and
 * removes a member behind a confirmation step (`DELETE .../members/{userId}`).
 *
 * The server is authoritative throughout (auth.md §5.3): admin-only + org-scope are re-enforced
 * regardless of the client, entity history is recorded server-side (FR-HIS-1), and the
 * **last-admin guard** (`409`, D-3) is surfaced here as a clear "can't remove the last admin"
 * message rather than reimplemented client-side.
 */
export function MemberManagement({ config, orgId }: MemberManagementProps) {
  const { t } = useTranslation();
  const { query, members, inviteMutation, removeMutation } = useMembers(config, orgId);

  // --- Invite form state ---------------------------------------------------------------------
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<InvitableRole>(DEFAULT_INVITE_ROLE);
  const [emailError, setEmailError] = useState<string | null>(null);
  const [inviteError, setInviteError] = useState<string | null>(null);
  const [inviteStatus, setInviteStatus] = useState<InviteStatus>("idle");
  const [invitedEmail, setInvitedEmail] = useState("");

  const emailRef = useRef<HTMLInputElement>(null);
  const inviteErrorRef = useRef<HTMLParagraphElement>(null);

  // --- Removal confirmation state ------------------------------------------------------------
  const [pendingRemoval, setPendingRemoval] = useState<Member | null>(null);
  const [removeError, setRemoveError] = useState<string | null>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);

  // Move focus into the confirmation dialog when it opens so it is announced and reachable.
  useEffect(() => {
    if (pendingRemoval) dialogRef.current?.focus();
  }, [pendingRemoval]);

  // Move focus to the invite form-level error once it appears.
  useEffect(() => {
    if (inviteError) inviteErrorRef.current?.focus();
  }, [inviteError]);

  function handleEmailChange(value: string): void {
    setEmail(value);
    if (emailError) setEmailError(null);
    setInviteStatus((prev) => (prev === "invited" ? "idle" : prev));
  }

  function mapInviteError(error: unknown): void {
    if (error instanceof ApiError && error.kind === "validation") {
      setEmailError(t("members.invite.errors.invalidEmail"));
      emailRef.current?.focus();
      return;
    }
    if (error instanceof ApiError && error.kind === "conflict") {
      setInviteError(t("members.invite.errors.alreadyInvited"));
      return;
    }
    setInviteError(
      error instanceof ApiError && error.kind === "network"
        ? t("error.network")
        : t("members.invite.errors.failed"),
    );
  }

  async function handleInvite(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (!orgId) return;

    setInviteError(null);
    setInviteStatus("idle");

    const errors = validateInviteForm({ email, role });
    if (errors.email) {
      setEmailError(
        errors.email === "required"
          ? t("members.invite.errors.emailRequired")
          : t("members.invite.errors.invalidEmail"),
      );
      emailRef.current?.focus();
      return;
    }
    setEmailError(null);

    const trimmedEmail = email.trim();
    setInviteStatus("inviting");
    try {
      await inviteMutation.mutateAsync({ orgId, invite: { email: trimmedEmail, role } });
      setInvitedEmail(trimmedEmail);
      setEmail("");
      // Reset the role to the least-privilege default so the next invite doesn't silently
      // inherit an elevated role the admin picked for the previous person.
      setRole(DEFAULT_INVITE_ROLE);
      setInviteStatus("invited");
    } catch (error) {
      setInviteStatus("idle");
      mapInviteError(error);
    }
  }

  function openRemoveDialog(member: Member, trigger: HTMLButtonElement): void {
    triggerRef.current = trigger;
    setRemoveError(null);
    setPendingRemoval(member);
  }

  function closeRemoveDialog(): void {
    setPendingRemoval(null);
    setRemoveError(null);
    // Return focus to the row control that opened the dialog, when it is still present.
    const trigger = triggerRef.current;
    if (trigger && document.body.contains(trigger)) trigger.focus();
    triggerRef.current = null;
  }

  async function handleConfirmRemove(): Promise<void> {
    if (!orgId || !pendingRemoval) return;
    setRemoveError(null);
    try {
      await removeMutation.mutateAsync({ orgId, userId: pendingRemoval.user_id });
      // Success: the roster is invalidated by the hook; drop the dialog and restore focus.
      setPendingRemoval(null);
      const trigger = triggerRef.current;
      if (trigger && document.body.contains(trigger)) trigger.focus();
      triggerRef.current = null;
    } catch (error) {
      // Keep the dialog open and explain why — the last-admin guard is the headline case (D-3).
      if (error instanceof ApiError && error.kind === "conflict") {
        setRemoveError(t("members.remove.errors.lastAdmin"));
        return;
      }
      if (error instanceof ApiError && error.kind === "not-found") {
        setRemoveError(t("members.remove.errors.notMember"));
        return;
      }
      setRemoveError(
        error instanceof ApiError && error.kind === "network"
          ? t("error.network")
          : t("members.remove.errors.failed"),
      );
    }
  }

  function handleDialogKeyDown(event: KeyboardEvent<HTMLDivElement>): void {
    if (event.key === "Escape") {
      event.stopPropagation();
      closeRemoveDialog();
      return;
    }
    // Trap focus inside the modal (WCAG 2.2 AA): Tab/Shift+Tab must cycle within the dialog
    // rather than escaping to the inert page behind the backdrop.
    if (event.key !== "Tab") return;
    const dialog = dialogRef.current;
    if (!dialog) return;
    const focusable = dialog.querySelectorAll<HTMLElement>(
      'button:not([disabled]), a[href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
    );
    if (focusable.length === 0) return;
    const first = focusable[0]!;
    const last = focusable[focusable.length - 1]!;
    const active = document.activeElement;
    if (event.shiftKey && (active === first || active === dialog)) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && active === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function roleLabel(memberRole: string): string {
    if (memberRole === "admin") return t("members.roles.admin");
    if (memberRole === "user") return t("members.roles.user");
    return memberRole;
  }

  function statusLabel(status: Member["status"]): string {
    return t(`members.statuses.${status}`);
  }

  const removing = removeMutation.isPending;

  return (
    <section className="stack" aria-labelledby="members-heading">
      <h1 id="members-heading">{t("members.heading")}</h1>
      <p className="muted">{t("members.intro")}</p>

      {/* --- Invite a member ------------------------------------------------------------- */}
      <form className="stack" onSubmit={handleInvite} noValidate aria-labelledby="invite-heading">
        <h2 id="invite-heading">{t("members.invite.heading")}</h2>

        {inviteError && (
          <p className="field-error" role="alert" tabIndex={-1} ref={inviteErrorRef}>
            {inviteError}
          </p>
        )}

        <div className="field">
          <label htmlFor="invite-email">{t("members.invite.emailLabel")}</label>
          <input
            id="invite-email"
            name="email"
            type="email"
            autoComplete="off"
            value={email}
            ref={emailRef}
            onChange={(e) => handleEmailChange(e.target.value)}
            required
            aria-required="true"
            aria-invalid={emailError ? true : undefined}
            aria-describedby={emailError ? "invite-email-error" : undefined}
          />
          {emailError && (
            <p id="invite-email-error" className="field-error" role="alert">
              {emailError}
            </p>
          )}
        </div>

        <div className="field">
          <label htmlFor="invite-role">{t("members.invite.roleLabel")}</label>
          <select
            id="invite-role"
            name="role"
            value={role}
            onChange={(e) => {
              if (isInvitableRole(e.target.value)) setRole(e.target.value);
            }}
          >
            {INVITABLE_ROLES.map((r) => (
              <option key={r} value={r}>
                {roleLabel(r)}
              </option>
            ))}
          </select>
        </div>

        {inviteStatus === "invited" && (
          <p className="notice notice-success" role="status">
            {t("members.invite.sent", { email: invitedEmail })}
          </p>
        )}

        <div className="nav-actions">
          <button type="submit" className="btn btn-primary" disabled={inviteStatus === "inviting"}>
            {inviteStatus === "inviting" ? t("members.invite.sending") : t("members.invite.submit")}
          </button>
        </div>
      </form>

      {/* --- Member roster --------------------------------------------------------------- */}
      <h2 id="roster-heading">{t("members.roster.heading")}</h2>
      {query.isLoading ? (
        <p className="muted" role="status">
          {t("members.roster.loading")}
        </p>
      ) : query.isError ? (
        <div className="stack" role="alert">
          <p>
            {query.error instanceof ApiError && query.error.kind === "network"
              ? t("error.network")
              : t("members.roster.loadFailed")}
          </p>
          <button type="button" className="btn btn-secondary" onClick={() => void query.refetch()}>
            {t("error.retry")}
          </button>
        </div>
      ) : members.length === 0 ? (
        <p className="muted">{t("members.roster.empty")}</p>
      ) : (
        <table className="data-table" aria-labelledby="roster-heading">
          <thead>
            <tr>
              <th scope="col">{t("members.roster.columns.member")}</th>
              <th scope="col">{t("members.roster.columns.role")}</th>
              <th scope="col">{t("members.roster.columns.status")}</th>
              <th scope="col">
                <span className="visually-hidden">{t("members.roster.columns.actions")}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {members.map((member) => (
              <tr key={member.user_id}>
                <td>
                  <code>{member.user_id}</code>
                </td>
                <td>{roleLabel(member.role)}</td>
                <td>{statusLabel(member.status)}</td>
                <td>
                  {member.status !== "removed" && (
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={(e) => openRemoveDialog(member, e.currentTarget)}
                      aria-label={t("members.remove.ariaLabel", { member: member.user_id })}
                    >
                      {t("members.remove.action")}
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {query.hasNextPage && (
        <div className="nav-actions">
          <button
            type="button"
            className="btn btn-secondary"
            onClick={() => void query.fetchNextPage()}
            disabled={query.isFetchingNextPage}
          >
            {query.isFetchingNextPage
              ? t("members.roster.loadingMore")
              : t("members.roster.loadMore")}
          </button>
        </div>
      )}

      {/* --- Remove confirmation dialog -------------------------------------------------- */}
      {pendingRemoval && (
        <div className="modal-backdrop">
          <div
            className="card stack modal"
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="remove-dialog-title"
            aria-describedby="remove-dialog-body"
            tabIndex={-1}
            ref={dialogRef}
            onKeyDown={handleDialogKeyDown}
          >
            <h2 id="remove-dialog-title">{t("members.remove.confirm.title")}</h2>
            <p id="remove-dialog-body">
              {t("members.remove.confirm.body", { member: pendingRemoval.user_id })}
            </p>

            {removeError && (
              <p className="field-error" role="alert">
                {removeError}
              </p>
            )}

            <div className="nav-actions">
              <button
                type="button"
                className="btn btn-danger"
                onClick={() => void handleConfirmRemove()}
                disabled={removing}
              >
                {removing
                  ? t("members.remove.confirm.removing")
                  : t("members.remove.confirm.confirm")}
              </button>
              <button
                type="button"
                className="btn btn-secondary"
                onClick={closeRemoveDialog}
                disabled={removing}
              >
                {t("members.remove.confirm.cancel")}
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
