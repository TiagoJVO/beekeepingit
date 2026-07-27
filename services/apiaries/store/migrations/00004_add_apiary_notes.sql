-- +goose Up
-- apiaries.apiaries.notes — optional free-text notes (FR-AP-8, #196), shown
-- on the apiary detail page's "temNotas" block (docs/design/prototype.md,
-- melargil-app.dc.html). Nullable/unbounded like `name` has no hard length
-- ceiling in the contract beyond a generous cap (10,000 chars, well past
-- any realistic field note) — just a safety bound against pathological
-- payloads, not a real product constraint.
ALTER TABLE apiaries.apiaries
    ADD COLUMN notes TEXT CHECK (notes IS NULL OR char_length(notes) <= 10000);

-- +goose Down
ALTER TABLE apiaries.apiaries DROP COLUMN IF EXISTS notes;
