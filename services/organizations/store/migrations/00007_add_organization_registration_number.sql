-- +goose Up
-- FR-AP-9 (#296, triaged from D-19): the beekeeper registration number issued
-- by the local authority (in Portugal, DGAV's `número de registo do
-- apicultor`).
--
-- WHY IT IS ON THE ORGANIZATION AND NOT ONLY ON THE APIARY. The authority
-- issues ONE number per BEEKEEPER and requires it displayed visibly at each of
-- that beekeeper's apiaries; the apiaries themselves are identified by their
-- coordinates, not by a number of their own. So the natural home is the
-- beekeeper, and the organization is this system's closest stand-in for one.
-- The per-apiary column added by the apiaries service's own migration is an
-- OVERRIDE, for the case of one organization covering several beekeepers — an
-- apiary's EFFECTIVE number is its own value when set, otherwise this default.
--
-- NOT NULL DEFAULT '' rather than a nullable column, matching `address`: the
-- REST layer already models "unset" as the empty string end-to-end
-- (OrganizationResponse.Address is a plain string, an explicit JSON null on
-- PATCH clears to ''), and a second, differently-shaped optionality here would
-- buy nothing but a nil check at every read.
--
-- 50 characters is generous for a registration identifier (Portugal's DGAV
-- numbers are far shorter) while still bounding the column; it mirrors the
-- API-side rune cap in
-- services/organizations/api/organizations.go so a value that passes validation
-- can never fail the constraint.
ALTER TABLE organizations.organizations
    ADD COLUMN registration_number TEXT NOT NULL DEFAULT '';

ALTER TABLE organizations.organizations
    ADD CONSTRAINT organizations_registration_number_check
    CHECK (char_length(registration_number) <= 50);

-- +goose Down
ALTER TABLE organizations.organizations
    DROP CONSTRAINT organizations_registration_number_check;

ALTER TABLE organizations.organizations
    DROP COLUMN registration_number;
