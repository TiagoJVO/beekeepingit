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
import { RoleCapabilities } from "./RoleCapabilities";

/** A pending, not-yet-confirmed role change: which member, and the role the admin picked for them. */
interface PendingRoleChange {
  readonly member: Member;
  readonly targetRole: InvitableRole;
}

/**
 * Keep Tab / Shift+Tab inside an open modal (WCAG 2.2 AA focus trap): rather than escaping to the
 * inert page behind the backdrop, focus cycles within the dialog. Shared by the remove and
 * role-change dialogs so both trap focus identically.
 */
function trapTabKey(event: KeyboardEvent<HTMLDivElement>, dialog: HTMLDivElement | null): void {
  if (event.key !== "Tab" || !dialog) return;
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

interface MemberManagementProps {
  config: AppConfig;
  /** The organization id being administered — the caller's own org, or an operator's selected org (#469). */
  orgId: string | undefined;
}

type InviteStatus = "idle" | "inviting" | "invited";

/**
 * View, invite, remove and re-role the caller's organization members — the admin member-management
 * screen (NFR-ROL-1, NFR-ROL-2, FR-ONB-3, FR-TEN-2, D-3, #74/#75). It reads the paginated roster
 * (`GET .../members`), invites by email with a chosen role (`POST .../invitations`), removes a member
 * behind a confirmation step (`DELETE .../members/{userId}`), and **changes an active member's role**
 * within the fixed `admin`/`user` model behind a confirmation step (`PATCH .../members/{userId}`,
 * #75). It also renders an accessible **role-capabilities reference** (`RoleCapabilities`) so an admin
 * can inspect what each role is allowed to do (NFR-ROL-1, auth.md §5.3).
 *
 * The server is authoritative throughout (auth.md §5.3): admin-only + org-scope are re-enforced
 * regardless of the client, the new role takes effect on the target's next request and is recorded in
 * entity history (FR-HIS-1), and the **last-admin guard** (`409`, D-3) is surfaced here as a clear
 * message (can't remove/demote the last admin) rather than reimplemented client-side.
 */
export function MemberManagement({ config, orgId }: MemberManagementProps) {
  const { t } = useTranslation();
  const { query, members, inviteMutation, removeMutation, changeRoleMutation } = useMembers(
    config,
    orgId,
  );

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

  // --- Role-change confirmation state --------------------------------------------------------
  const [pendingRoleChange, setPendingRoleChange] = useState<PendingRoleChange | null>(null);
  const [roleChangeError, setRoleChangeError] = useState<string | null>(null);
  const [roleChangeSuccess, setRoleChangeSuccess] = useState<string | null>(null);
  const roleDialogRef = useRef<HTMLDivElement>(null);
  const roleTriggerRef = useRef<HTMLSelectElement | null>(null);

  // Manage dialog focus as an effect (not inline in the handlers) so it runs *after* the render
  // that toggles the background `inert` (below): on open, move focus into the dialog so it is
  // announced and reachable; on close, restore focus to the row control that opened it — which
  // is only focusable again once the background is no longer inert.
  useEffect(() => {
    if (pendingRemoval) {
      dialogRef.current?.focus();
    } else if (triggerRef.current) {
      const trigger = triggerRef.current;
      triggerRef.current = null;
      if (document.body.contains(trigger)) trigger.focus();
    }
  }, [pendingRemoval]);

  useEffect(() => {
    if (pendingRoleChange) {
      roleDialogRef.current?.focus();
    } else if (roleTriggerRef.current) {
      const trigger = roleTriggerRef.current;
      roleTriggerRef.current = null;
      if (document.body.contains(trigger)) trigger.focus();
    }
  }, [pendingRoleChange]);

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
    // Focus is restored to the triggering control by the effect above once the dialog is gone.
    setPendingRemoval(null);
    setRemoveError(null);
  }

  async function handleConfirmRemove(): Promise<void> {
    if (!orgId || !pendingRemoval) return;
    setRemoveError(null);
    try {
      await removeMutation.mutateAsync({ orgId, userId: pendingRemoval.user_id });
      // Success: the roster is invalidated by the hook; drop the dialog (the effect restores focus).
      setPendingRemoval(null);
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
    trapTabKey(event, dialogRef.current);
  }

  function openRoleDialog(
    member: Member,
    targetRole: InvitableRole,
    trigger: HTMLSelectElement,
  ): void {
    roleTriggerRef.current = trigger;
    setRoleChangeError(null);
    setRoleChangeSuccess(null);
    setPendingRoleChange({ member, targetRole });
  }

  function closeRoleDialog(): void {
    // Focus is restored to the triggering role control by the effect above once the dialog is gone.
    setPendingRoleChange(null);
    setRoleChangeError(null);
  }

  function mapRoleChangeError(error: unknown): void {
    // The last-admin guard is the headline case (409, D-3): demoting the org's only admin is refused.
    if (error instanceof ApiError && error.kind === "conflict") {
      setRoleChangeError(t("members.changeRole.errors.lastAdmin"));
      return;
    }
    if (error instanceof ApiError && error.kind === "not-found") {
      setRoleChangeError(t("members.changeRole.errors.notMember"));
      return;
    }
    if (error instanceof ApiError && error.kind === "forbidden") {
      setRoleChangeError(t("members.changeRole.errors.forbidden"));
      return;
    }
    setRoleChangeError(
      error instanceof ApiError && error.kind === "network"
        ? t("error.network")
        : t("members.changeRole.errors.failed"),
    );
  }

  async function handleConfirmRoleChange(): Promise<void> {
    if (!orgId || !pendingRoleChange) return;
    const { member, targetRole } = pendingRoleChange;
    setRoleChangeError(null);
    try {
      await changeRoleMutation.mutateAsync({ orgId, userId: member.user_id, role: targetRole });
      // Success: the roster is invalidated by the hook and re-reads the new role. Announce the
      // change and drop the dialog (the effect restores focus to the row control).
      setRoleChangeSuccess(
        t("members.changeRole.success", {
          member: member.user_id,
          role: roleLabel(targetRole),
        }),
      );
      setPendingRoleChange(null);
    } catch (error) {
      // Keep the dialog open and explain why (the last-admin 409 is the headline case, D-3).
      mapRoleChangeError(error);
    }
  }

  function handleRoleDialogKeyDown(event: KeyboardEvent<HTMLDivElement>): void {
    if (event.key === "Escape") {
      event.stopPropagation();
      closeRoleDialog();
      return;
    }
    trapTabKey(event, roleDialogRef.current);
  }

  function handleRoleSelect(member: Member, value: string, control: HTMLSelectElement): void {
    // Ignore a re-selection of the member's current role, and narrow the native value to the fixed
    // admin/user set before treating it as a change to confirm.
    if (!isInvitableRole(value) || value === member.role) return;
    openRoleDialog(member, value, control);
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
  const changingRole = changeRoleMutation.isPending;
  // While either confirmation dialog is open, take the rest of the screen out of the tab order and
  // the accessibility tree (ARIA modal-dialog pattern, WCAG 4.1.2) so assistive tech and pointer
  // users can't reach the roster/invite controls behind the backdrop. Focus restore is handled by
  // the effects above, which run after this `inert` is lifted.
  const backgroundInert = pendingRemoval !== null || pendingRoleChange !== null;

  return (
    <section className="stack" aria-labelledby="members-heading">
      <div className="stack" inert={backgroundInert || undefined}>
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
            <button
              type="submit"
              className="btn btn-primary"
              disabled={inviteStatus === "inviting"}
            >
              {inviteStatus === "inviting"
                ? t("members.invite.sending")
                : t("members.invite.submit")}
            </button>
          </div>
        </form>

        {/* --- Role capabilities reference (inspect what each role can do — NFR-ROL-1) ------ */}
        <RoleCapabilities />

        {/* --- Member roster --------------------------------------------------------------- */}
        <h2 id="roster-heading">{t("members.roster.heading")}</h2>

        {/* Announce a successful role change to assistive tech without stealing focus. */}
        {roleChangeSuccess && (
          <p className="notice notice-success" role="status">
            {roleChangeSuccess}
          </p>
        )}

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
            <button
              type="button"
              className="btn btn-secondary"
              onClick={() => void query.refetch()}
            >
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
                    <div className="row-actions">
                      {/* A role picker only for an active member whose current role is one of the
                        fixed values — a role outside the enum (the open `MembershipRole` type)
                        can't be represented as a selected <option> without mis-displaying it, so
                        we fall back to the read-only Role column rather than risk a wrong baseline. */}
                      {member.status === "active" && isInvitableRole(member.role) && (
                        <div className="field field-inline">
                          <label htmlFor={`role-${member.user_id}`} className="visually-hidden">
                            {t("members.changeRole.selectLabel", { member: member.user_id })}
                          </label>
                          <select
                            id={`role-${member.user_id}`}
                            value={member.role}
                            onChange={(e) =>
                              handleRoleSelect(member, e.target.value, e.currentTarget)
                            }
                          >
                            {INVITABLE_ROLES.map((r) => (
                              <option key={r} value={r}>
                                {roleLabel(r)}
                              </option>
                            ))}
                          </select>
                        </div>
                      )}
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
                    </div>
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
      </div>

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

      {/* --- Role-change confirmation dialog --------------------------------------------- */}
      {pendingRoleChange && (
        <div className="modal-backdrop">
          <div
            className="card stack modal"
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="role-dialog-title"
            aria-describedby="role-dialog-body"
            tabIndex={-1}
            ref={roleDialogRef}
            onKeyDown={handleRoleDialogKeyDown}
          >
            <h2 id="role-dialog-title">{t("members.changeRole.confirm.title")}</h2>
            <p id="role-dialog-body">
              {t("members.changeRole.confirm.body", {
                member: pendingRoleChange.member.user_id,
                // Re-derive the "from" role from the live roster so a concurrent refetch can't leave
                // the confirmation showing a stale baseline; fall back to the snapshot if the member
                // has since dropped out of the loaded pages.
                from: roleLabel(
                  members.find((m) => m.user_id === pendingRoleChange.member.user_id)?.role ??
                    pendingRoleChange.member.role,
                ),
                to: roleLabel(pendingRoleChange.targetRole),
              })}
            </p>

            {roleChangeError && (
              <p className="field-error" role="alert">
                {roleChangeError}
              </p>
            )}

            <div className="nav-actions">
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => void handleConfirmRoleChange()}
                disabled={changingRole}
              >
                {changingRole
                  ? t("members.changeRole.confirm.changing")
                  : t("members.changeRole.confirm.confirm")}
              </button>
              <button
                type="button"
                className="btn btn-secondary"
                onClick={closeRoleDialog}
                disabled={changingRole}
              >
                {t("members.changeRole.confirm.cancel")}
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
