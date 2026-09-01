-- +goose Up
-- FR-AP-9 (#296, triaged from D-19): the per-apiary OVERRIDE of the
-- organization's DGAV beekeeper registration number.
--
-- WHY AN OVERRIDE RATHER THAN THE ONLY HOME FOR THE VALUE. DGAV issues ONE
-- `número de registo do apicultor` per BEEKEEPER, to be displayed visibly at
-- each of that beekeeper's apiaries; apiaries themselves are identified to
-- DGAV by their coordinates, not by a number of their own. Storing the number
-- only here would repeat one beekeeper's value across every apiary row. So the
-- default lives on the organization (organizations migration 00007) and this
-- column exists solely for the case D-19's triage called out: ONE organization
-- covering SEVERAL beekeepers, whose apiaries carry different numbers. An
-- apiary's EFFECTIVE number is this column when set, otherwise the org's.
--
-- Nullable (not NOT NULL DEFAULT '') unlike the organizations column, because
-- here NULL is meaningful and distinct from '': it means "no override — inherit
-- the organization's default", which is the normal case. The organizations
-- column has no such distinction to draw, hence the different shape.
--
-- The 50-character CHECK mirrors both the organizations column's own CHECK and
-- the API-side rune cap (maxDgavRegistrationNumberLength, api/write.go), so a
-- value that passes REST or sync-apply validation can never fail here.
ALTER TABLE apiaries.apiaries
    ADD COLUMN dgav_registration_number TEXT;

ALTER TABLE apiaries.apiaries
    ADD CONSTRAINT apiaries_dgav_registration_number_check
    CHECK (dgav_registration_number IS NULL OR char_length(dgav_registration_number) <= 50);

-- +goose Down
ALTER TABLE apiaries.apiaries
    DROP CONSTRAINT apiaries_dgav_registration_number_check;

ALTER TABLE apiaries.apiaries
    DROP COLUMN dgav_registration_number;
