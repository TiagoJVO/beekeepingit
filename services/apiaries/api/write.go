// Package api (this file) — the client-facing REST write routes
// (POST/PATCH/DELETE /v1/apiaries[/{apiaryId}], #31/FR-AP-1). These are for
// **online-only/direct callers** (the Admin App, scripts, tests): the field
// PWA never calls these — every field-client write rides the local-first
// sync path (sync.go's InternalSyncRouter), per walking-skeleton.md §4.4.
// Both paths write the same apiaries.apiaries table and must apply the same
// validation rules and the same history-recording contract (FR-HIS-1) — see
// validateCreate/validateUpdate below and sync.go's validateOp, and
// writeAuditLogTx below and sync.go's writeAuditLog.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

const maxNameLength = 200
const maxNotesLength = 10000
const maxPlaceLabelLength = 200

// apiaryCreateRequest is the POST /v1/apiaries request body (ApiaryCreate
// schema). id is client-supplied (offline-generatable UUID, api-contracts.md
// §4); hive_count defaults to 0 when omitted (schema default); notes is
// optional free-text (FR-AP-8, #196); place_label is an optional free-text
// place name (#252), independent of location's coordinates.
type apiaryCreateRequest struct {
	ID         string         `json:"id"`
	Name       string         `json:"name"`
	Location   *geoPointInput `json:"location"`
	HiveCount  *int32         `json:"hive_count"`
	Notes      *string        `json:"notes"`
	PlaceLabel *string        `json:"place_label"`
}

// apiaryUpdateRequest is the PATCH /v1/apiaries/{id} request body
// (ApiaryUpdate schema) — any subset of mutable fields. A field's zero value
// is indistinguishable from "not sent" for Location (already a pointer),
// HiveCount (pointer), Notes (pointer) and PlaceLabel (pointer); Name uses a
// separate "was the key present" check (nameSet) since Go can't otherwise
// tell "" apart from absent for a plain string field decoded from JSON.
type apiaryUpdateRequest struct {
	Name       *string        `json:"name"`
	Location   *geoPointInput `json:"location"`
	HiveCount  *int32         `json:"hive_count"`
	Notes      *string        `json:"notes"`
	PlaceLabel *string        `json:"place_label"`
}

// createApiary, updateApiary and deleteApiary are wired into apiaries.go's
// Router (the combined read+write /v1/apiaries surface) — chi doesn't
// support Mount-ing two separate routers at the identical pattern, so there
// is no separate WriteRouter constructor here.

func createApiary(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}

		var body apiaryCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		id, fieldErrs := validateCreate(body)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}
		hiveCount := int32(0)
		if body.HiveCount != nil {
			hiveCount = *body.HiveCount
		}
		now := time.Now().UTC()
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		var row sqlcgen.InsertApiaryWithLocationRow
		err := withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			var err error
			row, err = q.InsertApiaryWithLocation(r.Context(), sqlcgen.InsertApiaryWithLocationParams{
				ID:             pgID,
				OrganizationID: org,
				Name:           body.Name,
				Notes:          notesParam(body.Notes),
				PlaceLabel:     notesParam(body.PlaceLabel),
				UpdatedAt:      pgtype.Timestamptz{Time: now, Valid: true},
				Lon:            body.Location.lon(),
				Lat:            body.Location.lat(),
			})
			if isUniqueViolation(err) {
				// Idempotency (Idempotency-Key + client-generated UUID PK,
				// api-contracts.md §4): the id itself is the natural
				// idempotency anchor. A re-sent create with the same id and
				// the same content returns the original result (201,
				// unchanged) rather than erroring; a genuinely different
				// payload reusing the same id is a real conflict (409).
				//
				// The failed INSERT already aborted this tx (Postgres: any
				// error inside a transaction poisons it — every further
				// statement fails until rollback, which withTx's deferred
				// Rollback performs once this function returns), so the
				// lookup below runs on a fresh pool-backed Queries, not q.
				respondIdempotentCreateOrConflict(w, r, sqlcgen.New(pool), org, id, body, hiveCount)
				return errResponseWritten
			}
			if err != nil {
				return fmt.Errorf("insert apiary: %w", err)
			}

			// hive_count (#256): upserted into apiary_counters in the same
			// transaction as the just-inserted apiaries row — never a column
			// on that row itself. Uses the request's own hiveCount value
			// directly (there is nothing to join against yet for a
			// brand-new id, per InsertApiaryWithLocation's doc comment), so
			// the response DTO below and the history "want" state both
			// reflect exactly what the caller asked to create.
			// Unconditional here (unlike updateApiary's body.HiveCount
			// nil-guard): a REST create is a full-resource create whose
			// contract defaults hive_count to 0, and the id was just minted
			// by this caller — no offline device can hold a pending counter
			// edit for it, so there is no LWW interaction to protect.
			if err := upsertCounter(r.Context(), q, org, pgID, counterTypeHive, hiveCount, pgtype.Timestamptz{Time: now, Valid: true}); err != nil {
				return fmt.Errorf("upsert hive counter: %w", err)
			}

			want := restRowState{name: row.Name, hive: hiveCount, notes: textOf(row.Notes), placeLabel: textOf(row.PlaceLabel)}
			if err := writeAuditLogTx(r.Context(), q, org, userID, id, history.ChangeCreate, now, restRowState{}, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "create apiary failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.Header().Set("Location", "/v1/apiaries/"+uuidString(row.ID))
		w.Header().Set("ETag", etagFor(row.UpdatedAt))
		writeJSON(w, r, http.StatusCreated, apiaryDTO{
			ID:             uuidString(row.ID),
			OrganizationID: uuidString(row.OrganizationID),
			Name:           row.Name,
			HiveCount:      hiveCount,
			Location:       parseGeoJSONPoint(row.LocationGeojson),
			PlaceLabel:     textPtr(row.PlaceLabel),
			Notes:          textPtr(row.Notes),
			CreatedAt:      row.CreatedAt.Time,
			UpdatedAt:      row.UpdatedAt.Time,
		})
	}
}

// respondIdempotentCreateOrConflict handles createApiary's unique_violation
// branch: the id already exists in this org. Same content ⇒ 201 with the
// existing (unchanged) row, exactly as if this were the first successful
// create (idempotent replay never writes a second audit_log row — no
// domain change occurred). Different content, or the id belongs to a
// different org (existing row simply not found under org scope) ⇒ 409.
func respondIdempotentCreateOrConflict(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, org pgtype.UUID, id uuid.UUID, body apiaryCreateRequest, hiveCount int32) {
	existing, err := q.GetApiary(r.Context(), sqlcgen.GetApiaryParams{OrganizationID: org, ID: pgtype.UUID{Bytes: id, Valid: true}})
	if err != nil {
		// Not found under this org (id collides cross-org) or a genuine
		// lookup failure — either way, not a safe idempotent replay.
		problem.Write(w, r, problem.Conflict("an apiary with this id already exists"))
		return
	}
	sameLocation := existing.LocationGeojson == geoJSONOf(body.Location)
	sameNotes := textOf(existing.Notes) == strPtrValue(body.Notes)
	samePlaceLabel := textOf(existing.PlaceLabel) == strPtrValue(body.PlaceLabel)
	if existing.Name != body.Name || existing.HiveCount != hiveCount || !sameLocation || !sameNotes || !samePlaceLabel {
		problem.Write(w, r, problem.Conflict("an apiary with this id already exists with different content"))
		return
	}
	w.Header().Set("Location", "/v1/apiaries/"+uuidString(existing.ID))
	w.Header().Set("ETag", etagFor(existing.UpdatedAt))
	writeJSON(w, r, http.StatusCreated, apiaryDTO{
		ID:             uuidString(existing.ID),
		OrganizationID: uuidString(existing.OrganizationID),
		Name:           existing.Name,
		HiveCount:      existing.HiveCount,
		Location:       parseGeoJSONPoint(existing.LocationGeojson),
		PlaceLabel:     textPtr(existing.PlaceLabel),
		Notes:          textPtr(existing.Notes),
		CreatedAt:      existing.CreatedAt.Time,
		UpdatedAt:      existing.UpdatedAt.Time,
	})
}

// geoJSONOf renders p the same way ST_AsGeoJSON would for the equivalent
// stored point, so respondIdempotentCreateOrConflict can compare a request's
// location against the stored location_geojson column with a plain string
// comparison. nil ⇒ "" (matches the COALESCE(...,”)  no-location sentinel).
func geoJSONOf(p *geoPointInput) string {
	if p == nil {
		return ""
	}
	b, _ := json.Marshal(geoPointDTO{Type: "Point", Coordinates: [2]float64{p.Coordinates[0], p.Coordinates[1]}})
	return string(b)
}

// notesParam converts a request's optional nullable-text field (*string, nil
// = omitted) into the sqlc nullable text param InsertApiaryWithLocation/
// UpdateApiaryWithLocation expect — Valid:false clears/omits the field.
// Shared by both `notes` and `place_label` (#252): both are optional
// free-text columns with the identical "nil = omitted" wire shape, so one
// converter serves either call site — the parameter name stays generic
// rather than `notes`-specific now that a second field uses it.
func notesParam(value *string) pgtype.Text {
	if value == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *value, Valid: true}
}

// notesParamFromState is notesParam's counterpart for a restRowState's
// already-resolved string value ("" is its "unset" sentinel, matching
// location — see restRowState.notes/placeLabel). Shared by `notes` and
// `place_label` for the same reason notesParam is.
func notesParamFromState(value string) pgtype.Text {
	if value == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: value, Valid: true}
}

// textOf reads a stored pgtype.Text column back as a plain string ("" when
// unset) — the restRowState/idempotency-comparison counterpart of textPtr
// (which instead yields a DTO *string, nil when unset).
func textOf(t pgtype.Text) string {
	if !t.Valid {
		return ""
	}
	return t.String
}

// strPtrValue reads an optional request field (*string, nil = omitted) as a
// plain string ("" when omitted) — the request-side counterpart of textOf,
// so respondIdempotentCreateOrConflict can compare both sides the same way.
func strPtrValue(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func validateCreate(body apiaryCreateRequest) (uuid.UUID, []problem.FieldError) {
	var errs []problem.FieldError
	id, err := uuid.Parse(body.ID)
	if err != nil {
		errs = append(errs, problem.FieldError{Field: "id", Code: "invalid", Message: "id must be a UUID"})
	}
	name := body.Name
	switch {
	case strings.TrimSpace(name) == "":
		errs = append(errs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
	case len(name) > maxNameLength:
		errs = append(errs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
	}
	if body.HiveCount != nil && *body.HiveCount < 0 {
		errs = append(errs, problem.FieldError{Field: "hive_count", Code: "out_of_range", Message: "hive_count must be >= 0"})
	}
	if body.Notes != nil && len(*body.Notes) > maxNotesLength {
		errs = append(errs, problem.FieldError{Field: "notes", Code: "too_long", Message: "notes must be at most 10000 characters"})
	}
	if body.PlaceLabel != nil && len(*body.PlaceLabel) > maxPlaceLabelLength {
		errs = append(errs, problem.FieldError{Field: "place_label", Code: "too_long", Message: "place_label must be at most 200 characters"})
	}
	errs = append(errs, body.Location.validate("location")...)
	return id, errs
}

func updateApiary(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "apiaryId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("apiary not found"))
			return
		}

		var fields map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&fields); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}
		var body apiaryUpdateRequest
		if err := decodeFields(fields, &body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}
		_, nameSet := fields["name"]
		_, locationSet := fields["location"]

		if fieldErrs := validateUpdate(fields, body, nameSet); len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		pgID := pgtype.UUID{Bytes: id, Valid: true}
		var (
			updated sqlcgen.UpdateApiaryWithLocationRow
			want    restRowState
		)
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetApiaryForUpdate(r.Context(), sqlcgen.GetApiaryForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("apiary not found"))
				return errResponseWritten
			}

			if !ifMatchOK(r, etagFor(current.UpdatedAt)) {
				problem.Write(w, r, problem.Conflict("If-Match does not match the current version"))
				return errResponseWritten
			}

			before := restRowState{name: current.Name, hive: current.HiveCount, location: current.LocationGeojson, notes: textOf(current.Notes), placeLabel: textOf(current.PlaceLabel)}
			want = before
			if nameSet {
				want.name = *body.Name
			}
			if body.HiveCount != nil {
				want.hive = *body.HiveCount
			}
			_, notesSet := fields["notes"]
			if notesSet {
				want.notes = strPtrValue(body.Notes)
			}
			_, placeLabelSet := fields["place_label"]
			if placeLabelSet {
				want.placeLabel = strPtrValue(body.PlaceLabel)
			}
			var lon, lat pgtype.Float8
			if locationSet {
				want.location = geoJSONOf(body.Location)
				lon, lat = body.Location.lon(), body.Location.lat()
			} else {
				// Location untouched: re-send the currently stored point so
				// UpdateApiaryWithLocation (which always sets every mutable
				// column, mirroring sync.go's mergeOp) doesn't clear it.
				lon, lat = currentLonLat(current.LocationGeojson)
			}

			now := time.Now().UTC()
			nowTS := pgtype.Timestamptz{Time: now, Valid: true}
			var updateErr error
			updated, updateErr = q.UpdateApiaryWithLocation(r.Context(), sqlcgen.UpdateApiaryWithLocationParams{
				OrganizationID: org, ID: pgID,
				Name:       want.name,
				Notes:      notesParamFromState(want.notes),
				PlaceLabel: notesParamFromState(want.placeLabel),
				UpdatedAt:  nowTS,
				Lon:        lon, Lat: lat,
			})
			if updateErr != nil {
				return fmt.Errorf("update apiary: %w", updateErr)
			}

			// hive_count (#256): upserted into apiary_counters in the same
			// transaction — but ONLY when this PATCH actually carried it. A
			// hive-less PATCH (e.g. an Admin-App name edit) must not touch
			// the counter row at all: re-upserting the unchanged value would
			// bump the counter's own updated_at to server-now, which would
			// then LWW-supersede a field device's pending OFFLINE
			// hive-count edit (an older device timestamp) that had nothing
			// to conflict with — exactly the cross-field clobbering #256's
			// decoupling exists to prevent (sync.md §4.4's lossy case, now
			// solved for hive).
			if body.HiveCount != nil {
				if err := upsertCounter(r.Context(), q, org, pgID, counterTypeHive, want.hive, nowTS); err != nil {
					return fmt.Errorf("upsert hive counter: %w", err)
				}
			}

			if err := writeAuditLogTx(r.Context(), q, org, userID, id, history.ChangeUpdate, now, before, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "update apiary failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.Header().Set("ETag", etagFor(updated.UpdatedAt))
		writeJSON(w, r, http.StatusOK, apiaryDTO{
			ID:             uuidString(updated.ID),
			OrganizationID: uuidString(updated.OrganizationID),
			Name:           updated.Name,
			HiveCount:      want.hive,
			Location:       parseGeoJSONPoint(updated.LocationGeojson),
			PlaceLabel:     textPtr(updated.PlaceLabel),
			Notes:          textPtr(updated.Notes),
			CreatedAt:      updated.CreatedAt.Time,
			UpdatedAt:      updated.UpdatedAt.Time,
		})
	}
}

func validateUpdate(fields map[string]json.RawMessage, body apiaryUpdateRequest, nameSet bool) []problem.FieldError {
	var errs []problem.FieldError
	_, hiveSet := fields["hive_count"]
	_, locSet := fields["location"]
	_, notesSet := fields["notes"]
	_, placeLabelSet := fields["place_label"]
	if !nameSet && !hiveSet && !locSet && !notesSet && !placeLabelSet {
		errs = append(errs, problem.FieldError{Field: "(body)", Code: "required", Message: "request must change at least one field"})
	}
	if nameSet {
		switch {
		case body.Name == nil || strings.TrimSpace(*body.Name) == "":
			errs = append(errs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
		case len(*body.Name) > maxNameLength:
			errs = append(errs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
		}
	}
	if body.HiveCount != nil && *body.HiveCount < 0 {
		errs = append(errs, problem.FieldError{Field: "hive_count", Code: "out_of_range", Message: "hive_count must be >= 0"})
	}
	if body.Notes != nil && len(*body.Notes) > maxNotesLength {
		errs = append(errs, problem.FieldError{Field: "notes", Code: "too_long", Message: "notes must be at most 10000 characters"})
	}
	if body.PlaceLabel != nil && len(*body.PlaceLabel) > maxPlaceLabelLength {
		errs = append(errs, problem.FieldError{Field: "place_label", Code: "too_long", Message: "place_label must be at most 200 characters"})
	}
	errs = append(errs, body.Location.validate("location")...)
	return errs
}

func deleteApiary(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "apiaryId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("apiary not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetApiaryForUpdate(r.Context(), sqlcgen.GetApiaryForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("apiary not found"))
				return errResponseWritten
			}

			if !ifMatchOK(r, etagFor(current.UpdatedAt)) {
				problem.Write(w, r, problem.Conflict("If-Match does not match the current version"))
				return errResponseWritten
			}

			now := time.Now().UTC()
			rowsAffected, err := q.SoftDeleteApiary(r.Context(), sqlcgen.SoftDeleteApiaryParams{
				OrganizationID: org, ID: pgID, DeletedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if err != nil {
				return fmt.Errorf("soft delete apiary: %w", err)
			}
			if rowsAffected == 0 {
				problem.Write(w, r, problem.NotFound("apiary not found"))
				return errResponseWritten
			}

			before := restRowState{name: current.Name, hive: current.HiveCount, location: current.LocationGeojson, notes: textOf(current.Notes), placeLabel: textOf(current.PlaceLabel)}
			if err := writeAuditLogTx(r.Context(), q, org, userID, id, history.ChangeDelete, now, before, restRowState{}); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "delete apiary failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.WriteHeader(http.StatusNoContent)
	}
}

// ifMatchOK reports whether the request's If-Match header (if any) matches
// currentETag — optimistic concurrency for PATCH/DELETE (IfMatchHeader,
// contracts/openapi/_shared/components.openapi.yaml). An absent header is
// always OK (If-Match is optional per the contract); a present header must
// match exactly (or be the wildcard "*").
func ifMatchOK(r *http.Request, currentETag string) bool {
	want := r.Header.Get("If-Match")
	if want == "" || want == "*" {
		return true
	}
	return want == currentETag
}

// decodeFields re-marshals the already-decoded top-level fields map back to
// JSON and decodes it into dst — lets updateApiary get both the raw
// per-key presence (fields, a map) and a typed apiaryUpdateRequest from a
// single body read, without importing a JSON-patch/merge library.
func decodeFields(fields map[string]json.RawMessage, dst any) error {
	b, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, dst)
}

// currentLonLat re-derives lon/lat Float8 params from a stored
// location_geojson string (parseGeoJSONPoint's input shape) — used by
// updateApiary to re-assert the unchanged location on a PATCH that doesn't
// touch it, since UpdateApiaryWithLocation always sets the column.
func currentLonLat(locationGeojson string) (pgtype.Float8, pgtype.Float8) {
	pt := parseGeoJSONPoint(locationGeojson)
	if pt == nil {
		return pgtype.Float8{}, pgtype.Float8{}
	}
	return pgtype.Float8{Float64: pt.Coordinates[0], Valid: true}, pgtype.Float8{Float64: pt.Coordinates[1], Valid: true}
}

// restRowState is the REST write handlers' mutable projection of an apiary
// for history diffing — mirrors sync.go's rowState (same field set, plus
// location) so writeAuditLogTx produces the identical change-payload shape
// history.ComputeChange expects regardless of which write path (REST or
// sync-apply) produced it.
type restRowState struct {
	name       string
	hive       int32
	location   string // "" means unset, matching location_geojson's sentinel
	notes      string // "" means unset — an apiary's own free-text content, not personal data (§7.3)
	placeLabel string // "" means unset — a place NAME (e.g. "Montargil"), not personal data (#252, §7.3)
}

// fields projects a restRowState to the plain field map history.ComputeChange
// diffs — only soft/scalar values, never denormalized personal data (§7.3).
// location is included as its GeoJSON string (an opaque, non-personal
// value) so a location change shows up in the update delta; notes similarly
// (FR-AP-8, #196) — it's the apiary's own content, not personal data about
// a person; place_label (#252) likewise — a place name the apiary's owner
// chose, not personal data about anyone.
func (a restRowState) fields() map[string]any {
	m := map[string]any{"name": a.name, "hive_count": a.hive}
	if a.location != "" {
		m["location"] = a.location
	}
	if a.notes != "" {
		m["notes"] = a.notes
	}
	if a.placeLabel != "" {
		m["place_label"] = a.placeLabel
	}
	return m
}

// writeAuditLogTx appends one history.md §3 row for a REST create/update/
// delete, in the same local transaction as the domain write — the REST-path
// counterpart of sync.go's writeAuditLog, producing an identical row shape
// (history.md §4: history commits iff the change commits, on both the
// online and the sync-apply path).
func writeAuditLogTx(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, entityID uuid.UUID, changeType string, occurredAt time.Time, before, after restRowState) error {
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

	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeApiary,
		EntityID:       pgtype.UUID{Bytes: entityID, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: occurredAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// isUniqueViolation reports whether err is a Postgres unique_violation
// (SQLSTATE 23505) — the client-generated id already exists (mirrors
// organizations/api/organizations.go's helper of the same name/purpose).
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
