import type { InvitableRole } from "../api/members";

/** The user-editable fields of the invite form. */
export type InviteField = "email";

/** Machine-readable validation reasons — the component maps each to a localized message. */
export type InviteFieldErrorCode = "required" | "invalid";

export type InviteFieldErrors = Partial<Record<InviteField, InviteFieldErrorCode>>;

/** The raw invite-form values (as held in inputs — email untrimmed). */
export interface InviteFormValues {
  readonly email: string;
  readonly role: InvitableRole;
}

/** The two roles an invitee can be assigned at invite time (fixed model — NFR-ROL-1, D-3). */
export const INVITABLE_ROLES: readonly InvitableRole[] = ["user", "admin"];

/** The default role a new invitee is given (least privilege — a plain member). */
export const DEFAULT_INVITE_ROLE: InvitableRole = "user";

/** Narrow an arbitrary string (e.g. a native `<select>` value) to the fixed invitable-role set. */
export function isInvitableRole(value: string): value is InvitableRole {
  return (INVITABLE_ROLES as readonly string[]).includes(value);
}

// A deliberately conservative single-line email shape: a non-empty local part, an `@`, and a
// dotted domain with no spaces. It is only a fast-feedback UX gate — the server re-validates
// (OpenAPI `format: email`) and remains authoritative; a `422` it returns maps back onto the field.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Client-side validation of the invite form (fail-fast UX only, NFR-SEC-1). `email` is required
 * and must look like an address; `role` is constrained to the fixed `admin`/`user` model by the
 * control itself, so it is not re-checked here. The server re-validates and stays authoritative.
 */
export function validateInviteForm(values: InviteFormValues): InviteFieldErrors {
  const errors: InviteFieldErrors = {};

  const email = values.email.trim();
  if (email.length === 0) {
    errors.email = "required";
  } else if (!EMAIL_PATTERN.test(email)) {
    errors.email = "invalid";
  }

  return errors;
}
