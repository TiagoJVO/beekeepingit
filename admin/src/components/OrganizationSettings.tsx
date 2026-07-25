import { useEffect, useMemo, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { ApiError } from "../api/client";
import { ORG_ADDRESS_MAX_LENGTH, ORG_NAME_MAX_LENGTH } from "../api/organizations";
import type { AppConfig } from "../config/env";
import { useOrganization } from "../hooks/useOrganization";
import {
  isDirty,
  validateOrganizationForm,
  type OrgEditableField,
  type OrganizationFieldErrors,
} from "./organizationForm";

interface OrganizationSettingsProps {
  config: AppConfig;
}

type SaveStatus = "idle" | "saving" | "saved";

/** Display messages keyed by field, resolved from either client validation or a server `422`. */
type FieldMessages = Partial<Record<OrgEditableField, string>>;

/**
 * View and edit the caller's organization (name + address) — the org-management screen
 * (NFR-ROL-2, FR-ONB-2, #73). It reads the org (with its `ETag`) via `GET /organizations/me`
 * and persists edits through `PATCH /organizations/{orgId}` with `If-Match` optimistic
 * concurrency (FR-TEN-2): a `409` becomes a clear "someone else changed this, reload" alert; a
 * `422` maps field errors back onto the inputs and blocks the save. Entity history for the edit
 * is recorded server-side (FR-HIS-1, #289) — nothing to do here.
 */
export function OrganizationSettings({ config }: OrganizationSettingsProps) {
  const { t } = useTranslation();
  const { query, mutation } = useOrganization(config);

  const org = query.data?.data;
  const etag = query.data?.etag ?? null;
  const version = org?.updated_at ?? org?.id;

  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [fieldMessages, setFieldMessages] = useState<FieldMessages>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [conflict, setConflict] = useState(false);
  const [saveStatus, setSaveStatus] = useState<SaveStatus>("idle");

  const nameRef = useRef<HTMLInputElement>(null);
  const addressRef = useRef<HTMLTextAreaElement>(null);
  const conflictRef = useRef<HTMLDivElement>(null);
  const formErrorRef = useRef<HTMLParagraphElement>(null);

  // Sync the editable fields to the loaded record whenever a new server record arrives (initial
  // load, a successful save's cache replacement, or a post-conflict reload). Deliberately does
  // NOT touch `saveStatus`, so a just-saved success message survives the cache replacement it
  // itself triggered; the message is instead cleared when the user next edits a field.
  useEffect(() => {
    if (!org) return;
    setName(org.name);
    setAddress(org.address ?? "");
    setFieldMessages({});
    setFormError(null);
    setConflict(false);
  }, [org, version]);

  function handleNameChange(value: string): void {
    setName(value);
    setSaveStatus((prev) => (prev === "saved" ? "idle" : prev));
  }

  function handleAddressChange(value: string): void {
    setAddress(value);
    setSaveStatus((prev) => (prev === "saved" ? "idle" : prev));
  }

  const baseline = useMemo(
    () => ({ name: org?.name ?? "", address: org?.address ?? "" }),
    [org?.name, org?.address],
  );
  const dirty = isDirty({ name, address }, baseline);

  function messageForCode(field: OrgEditableField, code: "required" | "too_long"): string {
    if (field === "name") {
      return code === "required"
        ? t("orgSettings.errors.nameRequired")
        : t("orgSettings.errors.nameTooLong", { max: ORG_NAME_MAX_LENGTH });
    }
    return t("orgSettings.errors.addressTooLong", { max: ORG_ADDRESS_MAX_LENGTH });
  }

  function resolveClientErrors(errors: OrganizationFieldErrors): FieldMessages {
    const messages: FieldMessages = {};
    if (errors.name) messages.name = messageForCode("name", errors.name);
    if (errors.address) messages.address = messageForCode("address", errors.address);
    return messages;
  }

  function focusFirstError(messages: FieldMessages): void {
    if (messages.name) {
      nameRef.current?.focus();
    } else if (messages.address) {
      addressRef.current?.focus();
    }
  }

  function applyServerValidation(problemErrors: ApiError["problem"]): void {
    const messages: FieldMessages = {};
    let bodyError: string | null = null;
    for (const err of problemErrors?.errors ?? []) {
      if ((err.field === "name" || err.field === "address") && err.code) {
        messages[err.field] =
          err.code === "required" || err.code === "too_long"
            ? messageForCode(err.field, err.code)
            : err.message;
      } else {
        // Field-less or unknown-field errors (e.g. the "(body)" minProperties rule).
        bodyError = err.message || t("orgSettings.errors.saveFailed");
      }
    }
    if (Object.keys(messages).length === 0 && !bodyError) {
      bodyError = t("orgSettings.errors.saveFailed");
    }
    setFieldMessages(messages);
    setFormError(bodyError);
    if (Object.keys(messages).length > 0) {
      focusFirstError(messages);
    }
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (!org) return;

    setFormError(null);
    setConflict(false);
    setSaveStatus("idle");

    const clientErrors = validateOrganizationForm({ name, address });
    if (Object.keys(clientErrors).length > 0) {
      const messages = resolveClientErrors(clientErrors);
      setFieldMessages(messages);
      focusFirstError(messages);
      return;
    }
    setFieldMessages({});

    const trimmedAddress = address.trim();
    setSaveStatus("saving");
    try {
      await mutation.mutateAsync({
        orgId: org.id,
        update: { name: name.trim(), address: trimmedAddress === "" ? null : trimmedAddress },
        etag,
      });
      setSaveStatus("saved");
    } catch (error) {
      setSaveStatus("idle");
      if (error instanceof ApiError && error.kind === "conflict") {
        setConflict(true);
        return;
      }
      if (error instanceof ApiError && error.kind === "validation") {
        applyServerValidation(error.problem);
        return;
      }
      setFormError(
        error instanceof ApiError && error.kind === "network"
          ? t("error.network")
          : t("orgSettings.errors.saveFailed"),
      );
    }
  }

  // Move focus to the conflict alert once it appears so the message is announced and reachable.
  useEffect(() => {
    if (conflict) conflictRef.current?.focus();
  }, [conflict]);

  // Move focus to a form-level error (non-field save failure) once it appears.
  useEffect(() => {
    if (formError) formErrorRef.current?.focus();
  }, [formError]);

  function handleDiscard(): void {
    setName(baseline.name);
    setAddress(baseline.address);
    setFieldMessages({});
    setFormError(null);
    setSaveStatus("idle");
  }

  if (query.isLoading) {
    return (
      <p className="muted" role="status">
        {t("orgSettings.loading")}
      </p>
    );
  }

  if (query.isError || !org) {
    const kind = query.error instanceof ApiError ? query.error.kind : undefined;
    return (
      <div className="stack" role="alert">
        <p>{kind === "network" ? t("error.network") : t("orgSettings.errors.loadFailed")}</p>
        <button type="button" className="btn btn-secondary" onClick={() => void query.refetch()}>
          {t("error.retry")}
        </button>
      </div>
    );
  }

  const saving = saveStatus === "saving";

  return (
    <form
      className="stack"
      onSubmit={handleSubmit}
      noValidate
      aria-labelledby="org-settings-heading"
    >
      <h1 id="org-settings-heading">{t("orgSettings.heading")}</h1>
      <p className="muted">{t("orgSettings.intro")}</p>

      {conflict && (
        <div className="notice notice-danger" role="alert" tabIndex={-1} ref={conflictRef}>
          <p>{t("orgSettings.conflict.body")}</p>
          <button type="button" className="btn btn-secondary" onClick={() => void query.refetch()}>
            {t("orgSettings.conflict.reload")}
          </button>
        </div>
      )}

      {formError && (
        <p className="field-error" role="alert" tabIndex={-1} ref={formErrorRef}>
          {formError}
        </p>
      )}

      <div className="field">
        <label htmlFor="org-name">{t("orgSettings.fields.name")}</label>
        <input
          id="org-name"
          name="name"
          type="text"
          value={name}
          ref={nameRef}
          onChange={(e) => handleNameChange(e.target.value)}
          required
          maxLength={ORG_NAME_MAX_LENGTH}
          aria-required="true"
          aria-invalid={fieldMessages.name ? true : undefined}
          aria-describedby={fieldMessages.name ? "org-name-error" : undefined}
        />
        {fieldMessages.name && (
          <p id="org-name-error" className="field-error" role="alert">
            {fieldMessages.name}
          </p>
        )}
      </div>

      <div className="field">
        <label htmlFor="org-address">{t("orgSettings.fields.address")}</label>
        <textarea
          id="org-address"
          name="address"
          value={address}
          ref={addressRef}
          onChange={(e) => handleAddressChange(e.target.value)}
          rows={3}
          maxLength={ORG_ADDRESS_MAX_LENGTH}
          aria-invalid={fieldMessages.address ? true : undefined}
          aria-describedby={fieldMessages.address ? "org-address-error" : undefined}
        />
        {fieldMessages.address && (
          <p id="org-address-error" className="field-error" role="alert">
            {fieldMessages.address}
          </p>
        )}
      </div>

      {saveStatus === "saved" && (
        <p className="notice notice-success" role="status">
          {t("orgSettings.saved")}
        </p>
      )}

      <div className="nav-actions">
        <button type="submit" className="btn btn-primary" disabled={saving || !dirty}>
          {saving ? t("orgSettings.saving") : t("orgSettings.save")}
        </button>
        <button
          type="button"
          className="btn btn-secondary"
          onClick={handleDiscard}
          disabled={saving || !dirty}
        >
          {t("orgSettings.discard")}
        </button>
      </div>
    </form>
  );
}
