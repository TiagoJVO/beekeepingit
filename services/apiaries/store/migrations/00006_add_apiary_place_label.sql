-- +goose Up
-- apiaries.apiaries.place_label — optional free-text place name (e.g.
-- "Montargil"), #252/FR-AP-2/FR-AP-3/FR-AP-5. The map/proximity/measure
-- features already read the PostGIS `location` column (00003_add_apiary_
-- location.sql), but that column has no human-readable name attached — the
-- Melargil prototype's apiary form lets the beekeeper additionally name the
-- place itself (independent of the apiary's own `name`, e.g. an apiary named
-- "Colmeia 3" sited "Montargil"). Nullable/capped like `notes`
-- (00004_add_apiary_notes.sql): a place label is a short human label, not
-- free-form prose, but the same generous, non-product-meaningful safety
-- bound is reused rather than inventing a new arbitrary ceiling.
ALTER TABLE apiaries.apiaries
    ADD COLUMN place_label TEXT CHECK (place_label IS NULL OR char_length(place_label) <= 200);

-- +goose Down
ALTER TABLE apiaries.apiaries DROP COLUMN IF EXISTS place_label;
