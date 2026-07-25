import { ORG_ADDRESS_MAX_LENGTH, ORG_NAME_MAX_LENGTH } from "../api/organizations";

/** The user-editable fields of an organization on the management screen. */
export type OrgEditableField = "name" | "address";

/** Machine-readable validation reasons — the component maps each to a localized message. */
export type FieldErrorCode = "required" | "too_long";

export type OrganizationFieldErrors = Partial<Record<OrgEditableField, FieldErrorCode>>;

/** The raw form values (as held in inputs — untrimmed). */
export interface OrganizationFormValues {
  readonly name: string;
  readonly address: string;
}

/**
 * Client-side validation mirroring the server's `OrganizationUpdate` rules (NFR-SEC-1): `name`
 * is required and at most {@link ORG_NAME_MAX_LENGTH} characters; `address` is optional and at
 * most {@link ORG_ADDRESS_MAX_LENGTH}. Lengths count Unicode code points (via spread) rather
 * than UTF-16 units so PT diacritics are not over-counted, matching the server's rune counts.
 *
 * This is a fail-fast UX layer only — the server re-validates and remains authoritative; a `422`
 * it returns is mapped back onto the same fields.
 */
export function validateOrganizationForm(values: OrganizationFormValues): OrganizationFieldErrors {
  const errors: OrganizationFieldErrors = {};

  const name = values.name.trim();
  if (name.length === 0) {
    errors.name = "required";
  } else if ([...name].length > ORG_NAME_MAX_LENGTH) {
    errors.name = "too_long";
  }

  if ([...values.address.trim()].length > ORG_ADDRESS_MAX_LENGTH) {
    errors.address = "too_long";
  }

  return errors;
}

/** True when the edited values differ from the loaded record (drives the Save/Discard state). */
export function isDirty(values: OrganizationFormValues, baseline: OrganizationFormValues): boolean {
  return values.name !== baseline.name || values.address !== baseline.address;
}
