-- +goose Up
-- apiary_counters' UNIQUE(apiary_id, counter_type) (00005_create_apiary_
-- counters.sql) doubles as the upsert's ON CONFLICT target
-- (UpsertApiaryCounter) — but it omits organization_id. That's harmless for
-- the constraint's OWN job ("one row per apiary+type"), but it's also the
-- ON CONFLICT target the write path relies on, and it doesn't encode
-- tenancy at all. Defense in depth for the applyCounterOp tenancy guard
-- added alongside this migration (api/sync.go's applyCounterOp now checks
-- apiary ownership via GetApiaryForUpdate before ever reaching the upsert):
-- even if a future write path reached UpsertApiaryCounter without that
-- application-level check, the ON CONFLICT target itself now requires
-- organization_id to match too, so it can never silently collide with (and
-- overwrite) a DIFFERENT org's row for the same (apiary_id, counter_type) —
-- it would instead insert a genuinely new row (which the FK to
-- apiaries.apiaries plus the app-level org check make impossible to
-- populate meaningfully in practice, but the constraint itself no longer
-- permits a cross-tenant collision even in principle).
ALTER TABLE apiaries.apiary_counters
    DROP CONSTRAINT uq_apiary_counters_apiary_type;

ALTER TABLE apiaries.apiary_counters
    ADD CONSTRAINT uq_apiary_counters_org_apiary_type UNIQUE (organization_id, apiary_id, counter_type);

-- +goose Down
ALTER TABLE apiaries.apiary_counters
    DROP CONSTRAINT uq_apiary_counters_org_apiary_type;

ALTER TABLE apiaries.apiary_counters
    ADD CONSTRAINT uq_apiary_counters_apiary_type UNIQUE (apiary_id, counter_type);
