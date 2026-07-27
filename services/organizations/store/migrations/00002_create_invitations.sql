-- +goose Up
-- Email invitations to join an existing organization (D-3, FR-ONB-3, #27).
-- Shape per docs/architecture/data-model.md §3 (INVITATIONS entity) — invited
-- by email (no user_id yet: the invitee may not have an identity.users row
-- until their first login), accepted by matching the invitee's verified
-- profile email against a pending invitation (api/invitations.go).
CREATE TABLE organizations.invitations (
    id              UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations.organizations (id),
    email           TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
    invited_by      UUID NOT NULL,               -- soft ref -> identity.users (the inviting admin)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- At most one *pending* invitation per (org, email) — re-inviting the same
-- address while a pending invite already exists is a 409, not a duplicate
-- row (api/invitations.go). Accepted/expired/revoked rows are exempt so the
-- same email can be invited again after that invitation is resolved.
CREATE UNIQUE INDEX idx_invitations_org_email_pending
    ON organizations.invitations (organization_id, lower(email))
    WHERE status = 'pending';

-- The accept-on-login lookup (a verified profile email -> any pending
-- invitation for it, across all orgs) is the hot path every login exercises
-- via GET /organizations/me (§4.2-equivalent for this service).
CREATE INDEX idx_invitations_email_pending
    ON organizations.invitations (lower(email))
    WHERE status = 'pending';

-- +goose Down
DROP TABLE IF EXISTS organizations.invitations;
