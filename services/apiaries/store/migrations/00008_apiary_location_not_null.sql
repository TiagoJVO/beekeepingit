-- +goose Up
-- apiaries.apiaries.location is now MANDATORY (FR-AP-7, #341) — the product
-- owner directed that an apiary can never exist without coordinates, an
-- approved change to the previously-optional column added in
-- 00003_add_apiary_location.sql. Enforced here at the DB level (NOT NULL) to
-- match the form-validation, OpenAPI ApiaryCreate.required, REST/​sync
-- validation, and client-schema halves landed in the same change (D-20
-- precedent: coordinate the migration with the sync wire shape + client
-- schema in one change).
--
-- Backfill first (NOT NULL would fail if any existing row still held NULL):
-- any location-less row created before this rule is given the same
-- mainland-Portugal default the client's map picker falls back to
-- (apiary_form_screen.dart's _pickerFallbackCenter / apiary_map_screen.dart's
-- _fallbackCenter — 39.5°N, 8.0°W). This is a walking-skeleton-phase data
-- fix (dev-seed data only, no production apiaries yet); the beekeeper can
-- move the pin to the real site on the next edit. `public.`-qualified per
-- 00003's search_path note (the extension's types/functions live in `public`,
-- not the service's restricted search_path).
UPDATE apiaries.apiaries
SET location = public.ST_SetSRID(public.ST_MakePoint(-8.0, 39.5), 4326)::public.geography
WHERE location IS NULL;

ALTER TABLE apiaries.apiaries
    ALTER COLUMN location SET NOT NULL;

-- +goose Down
ALTER TABLE apiaries.apiaries
    ALTER COLUMN location DROP NOT NULL;
