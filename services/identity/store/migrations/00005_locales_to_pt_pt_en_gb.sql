-- +goose Up
-- D-34 (#656, NFR-I18N-1, C-2): the app's supported locales are European
-- Portuguese (`pt-PT`) and British English (`en-GB`). The generic `pt`/`en`
-- this column has stored since 00001 are NOT neutral — CLDR resolves them to
-- BRAZILIAN and AMERICAN conventions, so every date and grouped number was
-- rendered wrong for both of the app's intended audiences.
--
-- WHAT HAPPENS TO AN EXISTING ROW. Every stored value is rewritten to one of
-- the two supported tags; nobody is left on a code the app no longer offers.
-- The two statements are ORDER-DEPENDENT and together total: the first claims
-- every Portuguese row (`pt`, and defensively `pt_PT`/`pt-BR`/any other
-- region), the second sweeps everything that is left — `en`, and any value
-- that was never offered by the language picker — onto the default. Language
-- choice is preserved: a user who picked Portuguese stays on Portuguese.
--
-- The client ALSO normalizes on read (client/lib/core/l10n/
-- supported_locales.dart), so a profile that somehow still holds `pt` — read
-- from a stale offline cache, say — renders European Portuguese anyway. This
-- migration is what stops the value itself from lingering.
--
-- The CHECK is safe to add here precisely because the two UPDATEs above are
-- total, and because every writer now produces a supported tag: the API
-- normalizes a submitted locale before it reaches this column
-- (api/profile.go's normalizeLocale), first login inserts the column default
-- (queries/users.sql CreateUser), and the dev seed inserts devseed.UserLocale.
-- Adding a locale later means editing that set in all four places, which is
-- the point — it should be a deliberate act, not a silent free-text write.
UPDATE identity.users SET locale = 'pt-PT' WHERE locale ILIKE 'pt%';
UPDATE identity.users SET locale = 'en-GB' WHERE locale <> 'pt-PT';

ALTER TABLE identity.users
    ALTER COLUMN locale SET DEFAULT 'en-GB'::text;

ALTER TABLE identity.users
    ADD CONSTRAINT users_locale_supported
    CHECK (locale IN ('en-GB', 'pt-PT'));

-- +goose Down
ALTER TABLE identity.users
    DROP CONSTRAINT users_locale_supported;

ALTER TABLE identity.users
    ALTER COLUMN locale SET DEFAULT 'en'::text;

UPDATE identity.users SET locale = 'pt' WHERE locale = 'pt-PT';
UPDATE identity.users SET locale = 'en' WHERE locale = 'en-GB';
