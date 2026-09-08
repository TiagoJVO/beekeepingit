-- +goose Up
-- #641 (FR-ONB-3, FR-TEN-2, D-3): an invitation is now actually EMAILED to the
-- invited address, so the row has to record whether that send happened. Before
-- this migration `status` was the only state the admin screen could show, and
-- it read `pending` from the moment of creation forever — which everywhere else
-- in the product means "sent, awaiting response" while nothing had ever been
-- sent. Delivery is a SECOND, orthogonal axis: `status` stays the invitation's
-- lifecycle (pending/accepted/expired/revoked, the thing the invitee drives),
-- `delivery_status` is what the outbound email did (the thing the system
-- drives). Collapsing the two into one column would have made "accepted" and
-- "the email bounced" mutually exclusive, which they are not.
ALTER TABLE organizations.invitations
    ADD COLUMN delivery_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (delivery_status IN ('pending', 'sent', 'failed')),
    -- A SHORT, non-sensitive failure code (`smtp_unavailable`, `not_configured`,
    -- ...), never a raw error string: this value is rendered to an org admin,
    -- and the mailer deliberately keeps recipient data and relay credentials
    -- out of its errors (services/shared/mail). Bounded so a pathological
    -- driver error can never write an unbounded blob into a user-visible column.
    ADD COLUMN delivery_error TEXT NOT NULL DEFAULT '',
    -- How many send attempts (initial + admin-triggered resends) this
    -- invitation has had. Backs the resend cooldown's observability and lets
    -- an operator see a repeatedly-failing address without reading logs.
    ADD COLUMN delivery_attempts INTEGER NOT NULL DEFAULT 0,
    -- When the last send attempt finished (success or failure). NULL means
    -- "never attempted". Also the resend cooldown's clock (api/invitations.go).
    ADD COLUMN last_delivery_at TIMESTAMPTZ;

ALTER TABLE organizations.invitations
    ADD CONSTRAINT invitations_delivery_error_check
    CHECK (char_length(delivery_error) <= 200);

-- Honesty backfill (#641's whole point). Every invitation created before this
-- change was created by a code path with NO send step at all, so its email was
-- never sent. Leaving those rows at the column DEFAULT ('pending' = "a send is
-- in flight") would carry exactly the lie this issue exists to remove. Only
-- still-`pending` invitations are rewritten: an accepted/revoked/expired row's
-- lifecycle status is what the admin screen shows for it, and rewriting
-- resolved history to say something about a send that predates the feature
-- would be its own small dishonesty.
UPDATE organizations.invitations
SET delivery_status = 'failed',
    delivery_error  = 'never_sent'
WHERE status = 'pending';

-- Rate limiting (#641 security review): createInvitationHandler counts an
-- organization's recent invitations before accepting another one, so an admin
-- account cannot be turned into an open mail relay pointed at arbitrary
-- addresses. That count is (organization_id, created_at) — indexed here rather
-- than left to a sequential scan on the hot invite path.
CREATE INDEX invitations_organization_id_created_at_idx
    ON organizations.invitations (organization_id, created_at DESC);

-- The organization's own language (#641 AC 3: the invitation email is sent in
-- the recipient's language where known, "otherwise the organization's"). Same
-- two-locale domain as identity.users.locale — the app ships EN + PT
-- (NFR-I18N-1), and a CHECK keeps a third value from silently degrading to a
-- missing template. Seeded from the creating admin's own locale at
-- organization-creation time (D-3: the creator is the first admin), defaulting
-- to en-GB exactly like identity.users does for a profile with no preference.
ALTER TABLE organizations.organizations
    ADD COLUMN locale TEXT NOT NULL DEFAULT 'en-GB'
        CONSTRAINT organizations_locale_supported CHECK (locale IN ('en-GB', 'pt-PT'));

-- +goose Down
ALTER TABLE organizations.organizations
    DROP CONSTRAINT organizations_locale_supported;

ALTER TABLE organizations.organizations
    DROP COLUMN locale;

DROP INDEX organizations.invitations_organization_id_created_at_idx;

ALTER TABLE organizations.invitations
    DROP CONSTRAINT invitations_delivery_error_check;

ALTER TABLE organizations.invitations
    DROP COLUMN last_delivery_at,
    DROP COLUMN delivery_attempts,
    DROP COLUMN delivery_error,
    DROP COLUMN delivery_status;
