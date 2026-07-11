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
--
-- `public.geography` is schema-qualified: `CREATE EXTENSION postgis`
-- installs its types into the `public` schema (cluster.yaml's bootstrap), but
-- each service's runtime connection sets `search_path` to only its own
-- schema (DB_SEARCH_PATH, services/shared/dbaccess), which does not include
-- `public`. An unqualified `geography` reference fails to resolve under
-- that restricted search_path ("type \"geography\" does not exist") even
-- though the extension is installed — confirmed live against a real cluster
-- deploy, not just testcontainers (whose default search_path includes
-- `public`, silently masking this).
ALTER TABLE apiaries.apiaries
    ADD COLUMN location public.geography(Point, 4326);

CREATE INDEX idx_apiaries_location
    ON apiaries.apiaries
    USING GIST (location);

-- +goose Down
DROP INDEX IF EXISTS apiaries.idx_apiaries_location;
ALTER TABLE apiaries.apiaries DROP COLUMN IF EXISTS location;
