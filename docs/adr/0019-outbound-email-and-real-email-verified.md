# 0019 — Outbound email (SMTP) + a real `email_verified` claim via IdP flows

- **Status:** Accepted
- **Date:** 2026-07-23
- **Requirements:** NFR-SEC-1, NFR-CMP-1, NFR-TST-1, NFR-I18N-1
- **Decisions:** [D-7](../../requirements/decisions.md#d-7) (Authentik behind a
  provider-agnostic OIDC boundary), builds on [ADR-0016](0016-replace-keycloak-with-authentik.md)
- **Design:** [`docs/architecture/auth.md §8.10`](../architecture/auth.md),
  [`docs/architecture/oidc-integration.md §5/§8`](../architecture/oidc-integration.md)
- **Issue:** [#361](https://github.com/TiagoJVO/beekeepingit/issues/361)

## Context

The `email_verified` claim was cosmetic: Authentik's built-in email scope mapping hardcodes it —
`true` before upstream 2025.10, **`false` on the pinned 2026.5.4**. ADR-0016 accepted that with
"registration disabled is the actual control", but two things changed:

1. The **invitation accept-on-login gate** (#170, auth.md §8.7) only matches a pending invitation
   against the token's email **when `email_verified` is true** — on the pinned version the
   hardcoded `false` means that gate could **never fire in a live environment** (only Go tests
   with injected claims exercised it). The email-invitation feature was silently dead.
2. Any future feature that opens registration or links accounts by email needs the claim to mean
   something first — and working outbound email to deliver verification.

There was no outbound email at all (no SMTP config, no dev sink), and no
verification/recovery flows in the blueprint.

## Decision

### 1. The claim reflects a user attribute the IdP's own flows maintain

A **custom `email` scope mapping** (declared in the blueprint, attached to the provider in place
of the managed built-in) emits `request.user.attributes.get("email_verified", False) is True` —
Authentik's documented pattern for real verification state, with a strict boolean check that
fails closed on attribute junk. The app keeps depending only on the standard claim (D-7's
provider-agnostic boundary holds; a future IdP just has to emit an honest `email_verified`).

### 2. Verification is a login-time flow for existing accounts

Registration is disabled and accounts are invite/admin-provisioned, so verification is spliced
into the **authentication flow** (config-as-code in the blueprint): an email stage holds an
unverified, non-superuser login on an emailed one-time link; a user_write stage stamps the
attribute — gated on the plan's restored-flow-token evidence (`is_restored`), so completion of
the emailed link is the **only** path to the attribute. Superusers bypass (operator lockout
guard). Self-service email **changes are disabled** (`Tenant.default_user_change_email`, upstream
default `false` at 2026.5.4 — the review's live e2e found the settings flow rejects the change
outright), which closes the #170 privilege-escalation shape one layer down (a verified user
re-pointing their address at a victim's while keeping the claim) at the source; the setting is
not blueprint-manageable, so the pin is the version pin + the e2e asserting the rejection
(auth.md §8.10). A reset-on-change policy shipped in an earlier revision was removed as dead
config — it sat behind a validation that rejects the change first — and becomes mandatory again
only if that setting is ever deliberately enabled. Admin-driven email changes bypass the settings
flow and do not reset verification: an accepted operator-trust boundary.

_Rejected — standalone/portal-triggered verification flow:_ nothing would ever prompt
invite-provisioned users to run it, so invited users would stay unverified forever and the
invitation gate would stay dead in practice.

### 3. SMTP is infrastructure configuration; credentials never touch git

The upstream Authentik chart env-mounts every key of the existing config Secret
(`beekeepingit-authentik-config`), so the umbrella's authentik subchart renders the
`AUTHENTIK_EMAIL__*` connection keys from per-environment values — **zero changes to the external
gitops HelmRelease**. Relay credentials are read at render time from the out-of-band
`beekeepingit-authentik-email-credentials` Secret via `lookup` when it exists (ops create it per
environment) — the same cluster-state-not-git idiom as the generated credentials (NFR-SEC-1).

### 4. Dev/CI use a Mailpit sink; prod requires a real relay

A new `charts/mailpit` umbrella subchart (SMTP `:1025`, HTTP API/UI `:8025`, in-cluster only,
in-memory ring buffer) captures all dev/CI/staging outbound mail: the flow is testable end to end
and **no dev/CI mail can ever reach a real inbox**. Staging keeps the sink until a real
relay/domain exists (testers read verification mail via `kubectl port-forward`); prod disables it
and must configure a relay. NetworkPolicy gained an `ingressOnly` edge kind for it (the sending
Authentik pods are excluded from default-deny, so only the sink-side ingress allow may render).

### 5. EN/PT via Authentik's built-in localization (NFR-I18N-1) — EN-only in practice today

Authentik 2026.5.4 ships complete `en` and `pt_PT` catalogs for the account-confirmation
template, and the stage subject is deliberately the catalog msgid `Account Confirmation` so
translation engages the moment it can. Source-verifying the pin (during the #361 review) showed
flow-triggered mail cannot actually render `pt_PT` on 2026.5.4: sends translate per the
request's negotiated language (`User.locale()` prefers `request.LANGUAGE_CODE` whenever a
request is present), and `pt-PT` can never negotiate (Django's default `LANGUAGES` lacks
`pt-pt`; Authentik ships `pt_PT` but no plain `pt` catalog) — so verification emails render in
English regardless of user/browser locale until an upstream fix or a deployment-level
`LANGUAGES` override. Recorded on the oidc-integration.md §8 watch-list; the msgid subject
choice stands either way. _Limitation:_ the mail is also Authentik-branded — custom
BeekeepingIT templates would need volume mounts on the external HelmRelease; deferred until
branding matters.

## Consequences

- The invitation accept-on-login path works again in live environments — and only for users who
  actually proved inbox control. Unverified users are held at login until they verify (first
  login after this change re-verifies nobody: existing dev/CI seed state pins the test user
  verified; real users verify once via the emailed link).
- If SMTP breaks, unverified non-superuser logins are blocked at the email stage (verified users
  and superusers are unaffected). That is the accepted trade — fail closed on the claim, keep an
  operator path open.
- Password reset/recovery (EPIC-14 [#15](https://github.com/TiagoJVO/beekeepingit/issues/15)) now
  has its SMTP prerequisite in place; it remains out of scope here.
- An Authentik version bump must re-validate the blueprint's flow splice points (binding orders,
  the default flows' shapes) — recorded on oidc-integration.md §8's watch-list.
