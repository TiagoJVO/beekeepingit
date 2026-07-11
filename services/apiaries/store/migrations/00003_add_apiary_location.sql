-- +goose Up
-- apiaries.apiaries.location — PostGIS geography point (data-model.md §6, D-6),
-- deferred from 00001 to this issue (#31). Nullable: the OpenAPI ApiaryCreate
-- schema (contracts/openapi/apiaries.openapi.yaml) requires only `id`/`name`,
-- not `location` — matching the contract exactly, not over-constraining it.
--
-- The GIST index is added now (rather than in a later migration) because
-- proximity ordering (FR-AP-2, #33 — next wave) needs it and adding an index
-- is a cheap, purely additive change; this issue does not implement the
-- proximity query itself.
ALTER TABLE apiaries.apiaries
    ADD COLUMN location geography(Point, 4326);

CREATE INDEX idx_apiaries_location
    ON apiaries.apiaries
    USING GIST (location);

-- +goose Down
DROP INDEX IF EXISTS apiaries.idx_apiaries_location;
ALTER TABLE apiaries.apiaries DROP COLUMN IF EXISTS location;
