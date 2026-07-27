-- +goose Up
-- journeys.journeys.default_attributes — journey-level defaults for the
-- subtype attribute fields relevant to the journey's main_activity_type
-- (e.g. a Treatment journey's treatment_context/treatment_type/disease; a
-- Feeding journey's feed_type). Mirrors activities.activities.attributes'
-- JSONB-bag convention exactly so every layer (sqlc, sync, client) has an
-- existing pattern to copy — see issue #385 for the full design rationale.
-- Nullable; NULL means "no defaults set". Never deep-validated server-side
-- (services/journeys must not import the activities per-type attribute
-- schema); the client deep-validates at entry time and the activities
-- service revalidates fully once a default becomes a real activity
-- attribute (the prefill flow, issue #386).
ALTER TABLE journeys.journeys ADD COLUMN default_attributes JSONB;

-- +goose Down
ALTER TABLE journeys.journeys DROP COLUMN default_attributes;
