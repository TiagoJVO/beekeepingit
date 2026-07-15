package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// Op is one CRUD op in a client sync batch (walking-skeleton.md §5.1).
type Op struct {
	Op         string          `json:"op"`          // put | patch | delete
	EntityType string          `json:"entity_type"` // apiary
	ID         string          `json:"id"`
	Data       json.RawMessage `json:"data"`
	UpdatedAt  time.Time       `json:"updated_at"` // device time; LWW comparator (§4.3)
}

// Batch is one client transaction — the body of validate/apply.
type Batch struct {
	Ops []Op `json:"ops"`
}

// apiaryData is the sync wire shape for an entityTypeApiary op's `data`.
// LocationLon/LocationLat (#252) mirror the client's LOCAL PowerSync column
// names verbatim (client/lib/core/sync/powersync_schema.dart's
// `location_lon`/`location_lat` REAL columns) — the connector uploads a
// queued CRUD entry's opData as-is (powersync_connector.dart's `_toOp`, no
// per-column translation for the apiaries table, unlike the counter-identity
// enrichment it does for apiary_counters), so this is the plain
// lon/lat-per-key shape that arrives, not a nested GeoJSON object like the
// REST wire shape (geoPointInput) uses. Both are pointers, both-or-neither
// in practice (the client only ever writes both together — see
// apiaries_repository.dart's create/update), matching how REST's
// geoPointInput.lon()/lat() already produce a both-valid-or-both-NULL pair
// for the shared InsertApiary/UpdateApiary queries this data now flows into.
type apiaryData struct {
	Name        *string  `json:"name"`
	HiveCount   *int32   `json:"hive_count"`
	Notes       *string  `json:"notes"`
	PlaceLabel  *string  `json:"place_label"`
	LocationLon *float64 `json:"location_lon"`
	LocationLat *float64 `json:"location_lat"`
}

// counterData is the sync wire shape for an entityTypeApiaryCounter op
// (#256): apiary_id + counter_type identify WHICH counter this op targets —
// the client-generated Op.ID is only the local row's own PK (PowerSync's
// CRUD-queue key), never the server's identity for this row. The server's
// real uniqueness is (apiary_id, counter_type) — the table's UNIQUE
// constraint (00005_create_apiary_counters.sql) — so two different devices
// creating a "hive" counter for the same apiary offline generate two
// DIFFERENT client ids for what the server correctly collapses into ONE row
// via applyCounterOp's upsert. Value is a pointer (not a plain int32) so
// validateOp can distinguish "absent" (a patch with nothing to change) from
// "explicitly zero".
type counterData struct {
	ApiaryID    *string `json:"apiary_id"`
	CounterType *string `json:"counter_type"`
	Value       *int32  `json:"value"`
}

// Per-op apply outcomes (§5.2).
const (
	resultApplied    = "applied"
	resultSuperseded = "superseded"
)

// OpResult is the per-op result the coordinator relays to the client.
type OpResult struct {
	ID     string `json:"id"`
	Op     string `json:"op"`
	Result string `json:"result"` // applied | superseded
}

// ApplyResponse is the apply endpoint's body.
type ApplyResponse struct {
	Results []OpResult `json:"results"`
}

// InternalSyncRouter returns the internal sync validate/apply routes. Mount it
// under "/internal/sync" behind the OIDC authn + org-resolver middleware
// so the caller's org is resolved and re-checked here (zero-trust, §4.3).
func InternalSyncRouter(pool *pgxpool.Pool) http.Handler {
	r := chi.NewRouter()
	r.Post("/validate", validateBatch())
	r.Post("/apply", applyBatch(pool))
	return r
}

// validateBatch dry-runs every op against the same rules as the online write
// path, returning field-level RFC 9457 detail on the first-failing batch — and
// writing nothing (§6.2). On success it returns 200.
func validateBatch() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, _, ok := requireOrg(w, r); !ok {
			return
		}
		var batch Batch
		if err := json.NewDecoder(r.Body).Decode(&batch); err != nil {
			problem.Write(w, r, problem.ValidationFailed("malformed sync batch"))
			return
		}

		var fieldErrs []problem.FieldError
		for i, op := range batch.Ops {
			fieldErrs = append(fieldErrs, validateOp(i, op)...)
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more ops are invalid", fieldErrs...))
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"valid": true})
	}
}

// validateOp dry-runs one op against the same rules applyOp/applyCounterOp
// enforce, branching on entity_type (#256 adds entityTypeApiaryCounter
// alongside the original entityTypeApiary) — a single batch may freely mix
// both kinds of op.
func validateOp(i int, op Op) []problem.FieldError {
	switch op.EntityType {
	case entityTypeApiaryCounter:
		return validateCounterOp(i, op)
	default:
		return validateApiaryOp(i, op)
	}
}

// validateApiaryOp is the original entityTypeApiary validation (name/
// hive_count/notes on the apiaries row itself), now also validating
// location/place_label (#252) the same way the REST path's
// geoPointInput.validate/validateCreate do — a sync-apply write and a REST
// write must accept exactly the same content, per write.go's package doc
// comment. entity_type itself is validated permissively here (accepting
// either known type falls through to the matching validator; anything else
// is rejected as invalid, matching the pre-#256 "must be apiary" message's
// intent generalized to "must be a known type").
func validateApiaryOp(i int, op Op) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put, patch or delete"})
	}
	if op.EntityType != entityTypeApiary {
		errs = append(errs, problem.FieldError{Field: prefix + ".entity_type", Code: "invalid", Message: "entity_type must be apiary or apiary_counter"})
	}
	if _, err := uuid.Parse(op.ID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".id", Code: "invalid", Message: "id must be a UUID"})
	}
	if op.UpdatedAt.IsZero() {
		errs = append(errs, problem.FieldError{Field: prefix + ".updated_at", Code: "required", Message: "updated_at is required"})
	}

	if op.Op == "delete" {
		return errs
	}

	var data apiaryData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}
	if op.Op == "put" && (data.Name == nil || *data.Name == "") {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.name", Code: "required", Message: "name is required"})
	}
	if data.Name != nil && len(*data.Name) > 200 {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.name", Code: "too_long", Message: "name must be at most 200 characters"})
	}
	if data.HiveCount != nil && *data.HiveCount < 0 {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.hive_count", Code: "out_of_range", Message: "hive_count must be >= 0"})
	}
	if data.Notes != nil && len(*data.Notes) > 10000 {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.notes", Code: "too_long", Message: "notes must be at most 10000 characters"})
	}
	if data.PlaceLabel != nil && len(*data.PlaceLabel) > maxPlaceLabelLength {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.place_label", Code: "too_long", Message: "place_label must be at most 200 characters"})
	}
	// Location bounds (#252): mirrors geoPointInput.validate's lon/lat range
	// check — the wire shape differs (plain lon/lat keys, not a nested
	// GeoJSON point, per apiaryData's doc comment) but the rule is the same.
	// Both-or-neither is enforced here too: a lone lon or lat (the client
	// never produces this — both columns are always written together, see
	// apiaries_repository.dart) is rejected rather than silently treated as
	// "no location" or as 0 for the missing half.
	switch {
	case data.LocationLon != nil && data.LocationLat == nil:
		errs = append(errs, problem.FieldError{Field: prefix + ".data.location_lat", Code: "required", Message: "location_lat is required when location_lon is set"})
	case data.LocationLat != nil && data.LocationLon == nil:
		errs = append(errs, problem.FieldError{Field: prefix + ".data.location_lon", Code: "required", Message: "location_lon is required when location_lat is set"})
	case data.LocationLon != nil && data.LocationLat != nil:
		if *data.LocationLon < -180 || *data.LocationLon > 180 {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.location_lon", Code: "out_of_range", Message: "location_lon must be between -180 and 180"})
		}
		if *data.LocationLat < -90 || *data.LocationLat > 90 {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.location_lat", Code: "out_of_range", Message: "location_lat must be between -90 and 90"})
		}
	}
	if op.Op == "patch" && data.Name == nil && data.HiveCount == nil && data.Notes == nil &&
		data.PlaceLabel == nil && data.LocationLon == nil && data.LocationLat == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "required", Message: "patch must change at least one field"})
	}
	return errs
}

// validateCounterOp validates an entityTypeApiaryCounter op (#256): put/patch
// only (a counter has no independent delete — it has no lifecycle apart from
// its apiary, data-model.md §2's soft-delete convention doesn't apply to a
// row that's always either "the current value" or simply absent), a valid
// apiary_id, a KNOWN counter_type (the server-side half of #256 AC 2 — this
// is where an unknown type is actually rejected, unlike the always-hive
// wire shape apiary ops carry), and a non-negative value.
func validateCounterOp(i int, op Op) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put or patch for apiary_counter (counters have no delete)"})
	}
	if _, err := uuid.Parse(op.ID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".id", Code: "invalid", Message: "id must be a UUID"})
	}
	if op.UpdatedAt.IsZero() {
		errs = append(errs, problem.FieldError{Field: prefix + ".updated_at", Code: "required", Message: "updated_at is required"})
	}

	var data counterData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}
	if data.ApiaryID == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "required", Message: "apiary_id is required"})
	} else if _, err := uuid.Parse(*data.ApiaryID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
	}
	if data.CounterType == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.counter_type", Code: "required", Message: "counter_type is required"})
	} else if !isKnownCounterType(*data.CounterType) {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.counter_type", Code: "invalid", Message: "counter_type must be one of the known counter types"})
	}
	if data.Value == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.value", Code: "required", Message: "value is required"})
	} else if *data.Value < 0 {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.value", Code: "out_of_range", Message: "value must be >= 0"})
	}
	return errs
}

// applyBatch applies the batch in one local transaction: record-level LWW +
// conflict log + tombstones + idempotency on the client UUID PK (§4, §5.2).
func applyBatch(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		var batch Batch
		if err := json.NewDecoder(r.Body).Decode(&batch); err != nil {
			problem.Write(w, r, problem.ValidationFailed("malformed sync batch"))
			return
		}

		tx, err := pool.Begin(r.Context())
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		defer tx.Rollback(r.Context()) //nolint:errcheck // no-op after a successful Commit

		q := sqlcgen.New(tx)
		results := make([]OpResult, 0, len(batch.Ops))
		for _, op := range batch.Ops {
			var (
				res OpResult
				err error
			)
			if op.EntityType == entityTypeApiaryCounter {
				res, err = applyCounterOp(r.Context(), q, org, userID, op)
			} else {
				res, err = applyOp(r.Context(), q, org, userID, op)
			}
			if err != nil {
				problem.Write(w, r, problem.Internal())
				return
			}
			results = append(results, res)
		}

		if err := tx.Commit(r.Context()); err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		writeJSON(w, http.StatusOK, ApplyResponse{Results: results})
	}
}

// rowState is the mutable projection of an apiary the LWW logic reasons
// about. lon/lat (#252) are nil-together exactly when the apiary has no
// stored location — pointers rather than restRowState's GeoJSON-string
// sentinel, since this type reasons about the plain lon/lat wire shape
// directly (apiaryData's doc comment) with no GeoJSON round-trip needed
// internally.
type rowState struct {
	name       string
	hive       int32
	notes      string // "" means unset — an apiary's own free-text content, not personal data (§7.3)
	placeLabel string // "" means unset — a place NAME (e.g. "Montargil"), not personal data (#252, §7.3)
	lon        *float64
	lat        *float64
	deletedAt  pgtype.Timestamptz
}

func (a rowState) sameAs(b rowState) bool {
	return a.name == b.name && a.hive == b.hive && a.notes == b.notes && a.placeLabel == b.placeLabel &&
		floatPtrEqual(a.lon, b.lon) && floatPtrEqual(a.lat, b.lat) && a.deletedAt.Valid == b.deletedAt.Valid
}

// floatPtrEqual compares two optional float64s by value — nil-vs-nil is
// equal, nil-vs-set or differing values are not. Used by rowState.sameAs so
// a location change (including a set→unset or unset→set transition) is
// never mistaken for an idempotent no-op re-send.
func floatPtrEqual(a, b *float64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// fields projects a rowState to the plain field map history.ComputeChange
// diffs — only soft/scalar values, never denormalized personal data (§7.3).
// notes is the apiary's own content (FR-AP-8, #196), not personal data;
// place_label (#252) likewise. location (#252) is included as a "lon,lat"
// string (an opaque, non-personal value, mirroring restRowState.fields'
// GeoJSON-string treatment of the same column) so a location change shows
// up in the sync-apply update delta exactly like the REST path's.
func (a rowState) fields() map[string]any {
	m := map[string]any{"name": a.name, "hive_count": a.hive}
	if a.notes != "" {
		m["notes"] = a.notes
	}
	if a.placeLabel != "" {
		m["place_label"] = a.placeLabel
	}
	if a.lon != nil && a.lat != nil {
		m["location"] = fmt.Sprintf("%g,%g", *a.lon, *a.lat)
	}
	return m
}

func applyOp(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	var data apiaryData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}

	stored, err := q.GetApiaryForUpdate(ctx, sqlcgen.GetApiaryForUpdateParams{OrganizationID: org, ID: pgID})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	// No stored row: offline create (or a delete of something never seen).
	if missing {
		if op.Op == "delete" {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // nothing to tombstone
		}
		want := mergeOp(rowState{}, op, data)
		if err := q.InsertApiary(ctx, sqlcgen.InsertApiaryParams{
			ID: pgID, OrganizationID: org, Name: want.name,
			Notes:      notesParamFromState(want.notes),
			PlaceLabel: notesParamFromState(want.placeLabel),
			UpdatedAt:  incomingTS, DeletedAt: want.deletedAt,
			Lon: float8Ptr(want.lon), Lat: float8Ptr(want.lat),
		}); err != nil {
			return OpResult{}, err
		}
		// hive_count (#256): upserted into apiary_counters, not a column on
		// the just-inserted row — same local transaction (q wraps the
		// caller's pgx.Tx), so the apiary and its hive counter commit
		// together. ONLY when the op explicitly carries hive_count: the new
		// client sends the hive count as its own entityTypeApiaryCounter op
		// (same batch, same device timestamp) instead of embedding it here,
		// and an unconditional 0-value upsert at this op's timestamp would
		// make that sibling counter op lose LWW ("equal ts, different value"
		// ⇒ superseded in applyCounterOp) and silently drop the user's real
		// hive count. Absent hive_count ⇒ no counter row; every read path
		// COALESCEs to 0 (the "0 when no row exists" default, #256 AC).
		if data.HiveCount != nil {
			if err := upsertCounter(ctx, q, org, pgID, counterTypeHive, want.hive, incomingTS); err != nil {
				return OpResult{}, err
			}
		}
		if err := writeAuditLog(ctx, q, org, userID, op, history.ChangeCreate, rowState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	storedLon, storedLat := lonLatFromGeoJSON(stored.LocationGeojson)
	current := rowState{name: stored.Name, hive: stored.HiveCount, notes: textOf(stored.Notes), placeLabel: textOf(stored.PlaceLabel), lon: storedLon, lat: storedLat, deletedAt: stored.DeletedAt}
	want := mergeOp(current, op, data)

	// Strictly-newer incoming wins (§4.1).
	if op.UpdatedAt.After(stored.UpdatedAt.Time) {
		if err := q.UpdateApiary(ctx, sqlcgen.UpdateApiaryParams{
			OrganizationID: org, ID: pgID, Name: want.name,
			Notes:      notesParamFromState(want.notes),
			PlaceLabel: notesParamFromState(want.placeLabel),
			UpdatedAt:  incomingTS, DeletedAt: want.deletedAt,
			Lon: float8Ptr(want.lon), Lat: float8Ptr(want.lat),
		}); err != nil {
			return OpResult{}, err
		}
		// hive_count (#256): written only when the op explicitly carries it —
		// same reasoning as the create branch above (an op that doesn't
		// mention hive_count must not touch the counter row: it would bump
		// the counter's own updated_at and could LWW-supersede a legitimate
		// sibling entityTypeApiaryCounter op in the same batch). A delete op
		// never carries data, so it's excluded by the same nil check —
		// tombstoning an apiary isn't a hive-count change.
		if data.HiveCount != nil && op.Op != "delete" {
			if err := upsertCounter(ctx, q, org, pgID, counterTypeHive, want.hive, incomingTS); err != nil {
				return OpResult{}, err
			}
		}
		changeType := history.ChangeUpdate
		if op.Op == "delete" {
			changeType = history.ChangeDelete
		}
		if err := writeAuditLog(ctx, q, org, userID, op, changeType, current, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Equal or older. If it changes nothing, it is an idempotent re-send —
	// applied, no conflict. Otherwise the server value is kept and the loser
	// is logged (§4.1/§4.2).
	if want.sameAs(current) {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	if err := logConflict(ctx, q, org, userID, op, stored); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

// applyCounterOp applies one entityTypeApiaryCounter op (#256) — the
// apiary_counters counterpart of applyOp, but keyed by (apiary_id,
// counter_type) rather than the client-generated Op.ID: that id is only the
// local row's own PK on the client (PowerSync's CRUD-queue key), never the
// server's identity for a counter row, since two different devices creating
// the same apiary's "hive" counter offline generate two different client
// ids for what the server correctly collapses into ONE row (the table's
// UNIQUE(apiary_id, counter_type) constraint). LWW (§4.1) still applies,
// compared against the STORED counter row's own updated_at — record-level,
// same as applyOp, just for a one-field "record".
func applyCounterOp(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	var data counterData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}
	// validateOp already guarantees these are non-nil/well-formed by the time
	// apply runs (validate-first, sync.md §6.2) — applyBatch never reaches
	// apply on a batch that failed validate.
	apiaryID, err := uuid.Parse(*data.ApiaryID)
	if err != nil {
		return OpResult{}, err
	}
	pgApiaryID := pgtype.UUID{Bytes: apiaryID, Valid: true}
	counterType := *data.CounterType
	incomingValue := *data.Value
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	// Tenancy guard (FR-TEN-2, CRITICAL fix): the client-supplied apiary_id
	// must actually belong to the caller's org BEFORE any counter data is
	// read or written for it. Without this, an unknown/foreign apiary_id
	// makes GetApiaryCounter below miss (its own WHERE is org-scoped, so a
	// row that belongs to a different org simply never matches) and the
	// missing-branch below would treat that as "offline create" and upsert
	// UNCONDITIONALLY — letting any org inject/overwrite another org's
	// hive-count data via the table's ON CONFLICT (apiary_id, counter_type)
	// target, with no LWW check at all (mirrors applyOp's own org-scoped
	// GetApiaryForUpdate lookup, sync.md §4.3's zero-trust re-check). An
	// unknown/foreign apiary_id is a no-op (mirrors
	// TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow's "missing
	// row ⇒ nothing to do" convention for apiary ops) rather than a
	// distinguishable error — ADR-0002 scope-hiding, same as every other
	// cross-org read/write path in this service.
	if _, err := q.GetApiaryForUpdate(ctx, sqlcgen.GetApiaryForUpdateParams{
		OrganizationID: org, ID: pgApiaryID,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // unknown/foreign apiary: no-op
		}
		return OpResult{}, err
	}

	stored, err := q.GetApiaryCounter(ctx, sqlcgen.GetApiaryCounterParams{OrganizationID: org, ApiaryID: pgApiaryID, CounterType: counterType})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	// No stored row: offline create — always applies (nothing to compare
	// against, mirroring applyOp's own "missing ⇒ create" branch).
	if missing {
		if err := upsertCounter(ctx, q, org, pgApiaryID, counterType, incomingValue, incomingTS); err != nil {
			return OpResult{}, err
		}
		if err := writeCounterAuditLog(ctx, q, org, userID, op, history.ChangeCreate, apiaryID, counterType, nil, incomingValue); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Strictly-newer incoming wins (§4.1).
	if op.UpdatedAt.After(stored.UpdatedAt.Time) {
		if err := upsertCounter(ctx, q, org, pgApiaryID, counterType, incomingValue, incomingTS); err != nil {
			return OpResult{}, err
		}
		if err := writeCounterAuditLog(ctx, q, org, userID, op, history.ChangeUpdate, apiaryID, counterType, &stored.Value, incomingValue); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Equal or older. Same value ⇒ idempotent re-send, applied, no conflict.
	// Different value ⇒ the server value is kept and the loss is logged
	// (§4.1/§4.2), matching applyOp's own equal-or-older branch.
	if incomingValue == stored.Value {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	if err := logCounterConflict(ctx, q, org, userID, op, stored); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

// mergeOp computes the row an op would produce, given the current state (empty
// for a create). put replaces; patch overlays provided fields; delete sets the
// tombstone (§4.5).
//
// hive (#256): on put, an ABSENT hive_count preserves current.hive rather
// than resetting it to 0 — hive now lives in its own apiary_counters record
// (its writes ride the entityTypeApiaryCounter op or an explicit hive_count
// field), so a put that doesn't mention it must not claim it changed: the
// counter row wouldn't be written (applyOp's nil-guard), and a want.hive of
// 0 would make the audit diff record a 12→0 change that never actually
// happened. For a create, current is rowState{} (hive 0), so absent-on-create
// still yields the 0 default — same observable as before.
//
// location/place_label (#252): unlike hive, these follow the SAME full-replace
// convention `put` already applies to notes — an absent field on a put
// resets it to unset, since the client's local apiaries row always carries
// its current location_lon/location_lat/place_label together (they're plain
// columns on the same row, not a separate counter record), so a `put`
// genuinely is that row's complete content at write time, same as name/notes.
func mergeOp(current rowState, op Op, data apiaryData) rowState {
	switch op.Op {
	case "put":
		out := rowState{hive: current.hive}
		if data.Name != nil {
			out.name = *data.Name
		}
		if data.HiveCount != nil {
			out.hive = *data.HiveCount
		}
		if data.Notes != nil {
			out.notes = *data.Notes
		}
		if data.PlaceLabel != nil {
			out.placeLabel = *data.PlaceLabel
		}
		if data.LocationLon != nil && data.LocationLat != nil {
			out.lon, out.lat = data.LocationLon, data.LocationLat
		}
		return out
	case "delete":
		current.deletedAt = pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}
		return current
	default: // patch
		if data.Name != nil {
			current.name = *data.Name
		}
		if data.HiveCount != nil {
			current.hive = *data.HiveCount
		}
		if data.Notes != nil {
			current.notes = *data.Notes
		}
		if data.PlaceLabel != nil {
			current.placeLabel = *data.PlaceLabel
		}
		if data.LocationLon != nil && data.LocationLat != nil {
			current.lon, current.lat = data.LocationLon, data.LocationLat
		}
		return current
	}
}

// writeAuditLog appends one history.md §3 row for an applied create/update/
// delete, in the same local transaction as the domain write (§4). It must
// NOT be called for the no-op (idempotent replay) or LWW-loss branches of
// applyOp — those apply no domain change, so they get no audit row (§4
// "Idempotency"; §6 "LWW losers" go to sync_conflict_log instead, via
// logConflict, not here).
func writeAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, before, after rowState) error {
	var oldFields map[string]any
	if changeType != history.ChangeCreate {
		oldFields = before.fields()
	}
	newFields := after.fields()
	if changeType == history.ChangeDelete {
		newFields = nil
	}
	changedFields, change, err := history.ComputeChange(changeType, oldFields, newFields)
	if err != nil {
		return fmt.Errorf("compute apiary change: %w", err)
	}

	changeJSON, err := json.Marshal(change)
	if err != nil {
		return err
	}

	id, err := uuid.Parse(op.ID)
	if err != nil {
		return err
	}
	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeApiary,
		EntityID:       pgtype.UUID{Bytes: id, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

func logConflict(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, stored sqlcgen.GetApiaryForUpdateRow) error {
	winning, err := json.Marshal(map[string]any{
		"id":          uuidString(stored.ID),
		"name":        stored.Name,
		"hive_count":  stored.HiveCount,
		"notes":       textPtr(stored.Notes),
		"place_label": textPtr(stored.PlaceLabel),
		"location":    parseGeoJSONPoint(stored.LocationGeojson),
		"updated_at":  stored.UpdatedAt.Time,
		"deleted_at":  timePtr(stored.DeletedAt),
	})
	if err != nil {
		return err
	}
	losing, err := json.Marshal(op)
	if err != nil {
		return err
	}

	conflictID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertConflict(ctx, sqlcgen.InsertConflictParams{
		ID:             conflictID,
		OrganizationID: org,
		EntityType:     entityTypeApiary,
		EntityID:       stored.ID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}

// writeCounterAuditLog is writeAuditLog's counterpart for an applied
// entityTypeApiaryCounter create/update (#256) — counters have no delete
// (validateCounterOp), so there is no ChangeDelete branch to mirror.
// entity_id is the apiary_id (a counter row has no client-stable id of its
// own — see applyCounterOp's doc comment), so this apiary's combined history
// timeline (apiaries.audit_log rows for entity_type=apiary AND
// entity_type=apiary_counter, both keyed by the same apiary_id) reads as one
// coherent per-apiary story: "this apiary's name changed... this apiary's
// hive counter changed...". before is nil on create (baseline, matching
// writeAuditLog's own create convention); non-nil on update, diffed via
// history.ComputeChange exactly like every other field this service audits.
func writeCounterAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, apiaryID uuid.UUID, counterType string, before *int32, after int32) error {
	var oldFields map[string]any
	if before != nil {
		oldFields = map[string]any{counterType: *before}
	}
	newFields := map[string]any{counterType: after}
	changedFields, change, err := history.ComputeChange(changeType, oldFields, newFields)
	if err != nil {
		return fmt.Errorf("compute counter change: %w", err)
	}

	changeJSON, err := json.Marshal(change)
	if err != nil {
		return err
	}

	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeApiaryCounter,
		EntityID:       pgtype.UUID{Bytes: apiaryID, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// logCounterConflict is logConflict's counterpart for an LWW-losing
// entityTypeApiaryCounter op (#256): the losing offline edit is preserved
// (history.md §6 "LWW losers are not lost"), not silently dropped, exactly
// like an apiary-op conflict — just against the counter's (apiary_id,
// counter_type, value) shape instead of the full apiary row. The losing
// (incoming) value itself doesn't need its own parameter — it's already
// captured verbatim in the marshaled losing payload below (op.Data carries
// it), mirroring how logConflict's own losing payload is just json.Marshal(op).
func logCounterConflict(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, stored sqlcgen.ApiariesApiaryCounter) error {
	winning, err := json.Marshal(map[string]any{
		"apiary_id":    uuidString(stored.ApiaryID),
		"counter_type": stored.CounterType,
		"value":        stored.Value,
		"updated_at":   stored.UpdatedAt.Time,
	})
	if err != nil {
		return err
	}
	losing, err := json.Marshal(op)
	if err != nil {
		return err
	}

	conflictID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertConflict(ctx, sqlcgen.InsertConflictParams{
		ID:             conflictID,
		OrganizationID: org,
		EntityType:     entityTypeApiaryCounter,
		EntityID:       stored.ApiaryID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}

func parseActor(userID string) pgtype.UUID {
	u, err := uuid.Parse(userID)
	if err != nil {
		return pgtype.UUID{Valid: false}
	}
	return pgtype.UUID{Bytes: u, Valid: true}
}

func timePtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}
