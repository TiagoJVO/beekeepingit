-- +goose Up
-- FR-AP-10 (#298, triaged from D-19): stock declarations — a point-in-time
-- record of the hive stock a beekeeper declared to their authority (Portugal's
-- "Declaração de Existências" to DGAV is the motivating example).
--
-- DISTINCT FROM THE LIVE HIVE COUNTER, and that distinction is the whole point.
-- apiary_counters (#256, D-20) holds CURRENT STATE — "how many hives are here
-- now". A declaration holds WHAT WAS DECLARED ON A DATE, and stays true after
-- the live count moves on. Storing one as the other would destroy exactly the
-- history the regulation is about.
--
-- SCOPED TO A REGISTRATION NUMBER, NOT TO AN APIARY. The real declaration covers
-- a BEEKEEPER's whole holding, so it is keyed by the beekeeper registration
-- number (FR-AP-9) rather than by apiary_id — an organization covering several
-- beekeepers files one declaration per number. The number is stored as a plain
-- text VALUE, deliberately not a foreign key: it is the number as it stood when
-- the declaration was filed, and must not shift retroactively if the
-- organization's or an apiary's number is later corrected. `''` is a legitimate
-- value (a beekeeper who has not recorded a number yet still gets one
-- declaration group).
--
-- breakdown is the per-apiary snapshot taken at record time
-- ([{apiary_id, name, hive_count}, ...]), so a declaration still shows what it
-- covered after apiaries are renamed, re-counted, or deleted. JSONB per
-- data-model.md's convention for per-record attribute bags; no FK into apiaries
-- for the same "snapshot, not live join" reason.
--
-- deleted_at gives declarations the ordinary soft-delete lifecycle (unlike
-- apiary_counters, which has none): a declaration IS an independent record with
-- its own identity, so a mis-entered one must be removable and the tombstone
-- must propagate to other devices (data-model.md's soft-delete convention).
CREATE TABLE apiaries.stock_declarations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    registration_number text NOT NULL DEFAULT '',
    declared_on date NOT NULL,
    total_hive_count integer NOT NULL,
    breakdown jsonb NOT NULL DEFAULT '[]'::jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT stock_declarations_pkey PRIMARY KEY (id),
    CONSTRAINT stock_declarations_total_hive_count_check CHECK ((total_hive_count >= 0)),
    CONSTRAINT stock_declarations_registration_number_check CHECK ((char_length(registration_number) <= 50)),
    CONSTRAINT stock_declarations_notes_check CHECK (((notes IS NULL) OR (char_length(notes) <= 2000))),
    CONSTRAINT stock_declarations_breakdown_is_array CHECK ((jsonb_typeof(breakdown) = 'array'))
);

-- The one read the app actually performs: a registration number's declarations,
-- newest first, tombstones excluded — the declarations section's per-number log.
CREATE INDEX idx_stock_declarations_org_number_date
    ON apiaries.stock_declarations
    USING btree (organization_id, registration_number, declared_on DESC)
    WHERE (deleted_at IS NULL);

-- +goose Down
DROP TABLE apiaries.stock_declarations;
