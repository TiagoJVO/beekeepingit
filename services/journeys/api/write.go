// Package api (this file) — the client-facing REST create/update/delete
// routes (POST/PATCH/DELETE /v1/journeys[/{id}], #45, FR-JO-4, FR-TEN-2,
// FR-HIS-1). Like activities'/apiaries' own write.go, these serve
// **online-only/direct callers** (the Admin App, scripts, tests); the field
// PWA writes journeys through the local-first sync path instead (sync.go's
// InternalSyncRouter), per walking-skeleton.md §4.4. Both paths write the
// same journeys.journeys/journeys.journey_plan_items tables and must apply
// the same validation, tenancy and history-recording rules — see
// validateJourneyFields (types.go) and sync.go's validateJourneyOp/
// validateJourneyPlanItemOp, and writeJourneyAuditLogTx here and sync.go's
// writeJourneyAuditLog.
//
// PATCH's `apiary_ids` is a FULL RESUBMIT of the journey's desired plan (like
// activities' edit form always resubmitting the complete attributes bag) —
// this handler diffs it against the currently-stored plan and only writes
// the rows that actually changed (an unaffected apiary keeps its original
// `journey_plan_items` row/created_at). "Closing" a journey (D-21) rides the
// same PATCH via the optional `status` field — no separate endpoint, matching
// activities' single-PATCH-does-everything style, and this PR's Flutter
// client only ever sends `status` alongside the journey's OTHER
// already-loaded fields (never status-only), so PATCH's shape stays
// uniform: name/main_activity_type/apiary_ids are always required, status is
// always optional.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/journeys/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// maxCreateBodyBytes caps the raw request body for POST/PATCH /v1/journeys —
// a journey payload is a handful of known keys plus a bounded apiary_ids
// list (types.go's maxApiaryIDsPerJourney) — via http.MaxBytesReader,
// mirroring activities' maxCreateBodyBytes.
const maxCreateBodyBytes = 256 << 10 // 256 KiB

// journeyCreateRequest is the POST /v1/journeys request body. id is
// client-supplied (offline-generatable UUID, matching activities'/apiaries'
// own *CreateRequest.ID convention) — the natural idempotency anchor for a
// re-sent create. apiary_ids are CROSS-SERVICE references (apiaries_client.go's
// doc comment) — every one is verified against the caller's org before
// anything is written. A brand-new journey always starts `status: "open"`
// (D-21) — there is no client-supplied status on create.
type journeyCreateRequest struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	MainActivityType string   `json:"main_activity_type"`
	ApiaryIDs        []string `json:"apiary_ids"`
}

// journeyUpdateRequest is the PATCH /v1/journeys/{id} request body (#45,
// FR-JO-4, D-21). Like activities' activityUpdateRequest, the edit form
// always resubmits the COMPLETE current state for name/main_activity_type/
// apiary_ids (this package's own doc comment) — all three are REQUIRED here.
// status is the one genuinely optional field: absent means "leave the
// journey's current status unchanged"; present must be a known status
// (types.go's IsKnownStatus) — this is D-21's "close a journey" action,
// riding the same PATCH rather than a dedicated endpoint.
type journeyUpdateRequest struct {
	Name             string   `json:"name"`
	MainActivityType string   `json:"main_activity_type"`
	ApiaryIDs        []string `json:"apiary_ids"`
	Status           *string  `json:"status"`
}

// journeyDTO is the client-facing journey shape. apiary_ids reflects the
// journey's CURRENT live plan (journeys.journey_plan_items rows with
// deleted_at IS NULL), sorted for a deterministic wire order.
type journeyDTO struct {
	ID               string    `json:"id"`
	OrganizationID   string    `json:"organization_id"`
	Name             string    `json:"name"`
	MainActivityType string    `json:"main_activity_type"`
	Status           string    `json:"status"`
	ApiaryIDs        []string  `json:"apiary_ids"`
	CreatedAt        time.Time `json:"created_at"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// Router returns the client-facing /v1/journeys surface: create, update
// (including the full plan-items replace and the D-21 close transition) and
// delete.
func Router(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/", createJourney(pool, verifier))
	r.Patch("/{journeyId}", updateJourney(pool, verifier))
	r.Delete("/{journeyId}", deleteJourney(pool))
	return r
}

func createJourney(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCreateBodyBytes)
		var body journeyCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		id, err := uuid.Parse(body.ID)
		var fieldErrs []problem.FieldError
		if err != nil {
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "id", Code: "invalid", Message: "id must be a UUID"})
		}
		apiaryIDs, moreErrs := validateJourneyFields(body.Name, body.MainActivityType, body.ApiaryIDs)
		fieldErrs = append(fieldErrs, moreErrs...)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// CRITICAL tenancy guard (mirrors activities' own carry-over of #38's
		// review, #284): every apiary_id must belong to the CALLER'S
		// organization, verified via the owning service (apiaries_client.go),
		// BEFORE any row is inserted — de-duplicated to one upstream call per
		// distinct id (verifyApiaryIDs).
		bearer := r.Header.Get("Authorization")
		owned, err := verifyApiaryIDs(r.Context(), verifier, bearer, apiaryIDs)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		if errs := unownedApiaryFieldErrors(apiaryIDs, owned); len(errs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", errs...))
			return
		}

		now := time.Now().UTC()
		nowTS := pgtype.Timestamptz{Time: now, Valid: true}
		pgID := pgtype.UUID{Bytes: id, Valid: true}
		apiaryIDStrings := uuidStrings(apiaryIDs)

		var row sqlcgen.JourneysJourney
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			var insertErr error
			row, insertErr = q.InsertJourney(r.Context(), sqlcgen.InsertJourneyParams{
				ID: pgID, OrganizationID: org, Name: body.Name,
				MainActivityType: body.MainActivityType, Status: StatusOpen, UpdatedAt: nowTS,
			})
			if isUniqueViolation(insertErr) {
				// Idempotency (the client-generated id is the natural anchor,
				// same convention as activities/apiaries): a re-sent create
				// with the same id and the same content returns the original
				// result unchanged; a genuinely different payload reusing the
				// same id is a real conflict.
				respondIdempotentCreateOrConflict(r.Context(), w, r, sqlcgen.New(pool), org, id, body.Name, body.MainActivityType, apiaryIDStrings)
				return errResponseWritten
			}
			if insertErr != nil {
				return fmt.Errorf("insert journey: %w", insertErr)
			}

			for _, apiaryID := range apiaryIDs {
				if _, err := q.InsertJourneyPlanItem(r.Context(), sqlcgen.InsertJourneyPlanItemParams{
					ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, OrganizationID: org,
					JourneyID: pgID, ApiaryID: pgtype.UUID{Bytes: apiaryID, Valid: true},
				}); err != nil {
					return fmt.Errorf("insert journey plan item: %w", err)
				}
			}

			want := journeyRowState{name: body.Name, mainActivityType: body.MainActivityType, status: StatusOpen, apiaryIDs: sortedStrings(apiaryIDStrings)}
			if err := writeJourneyAuditLogTx(r.Context(), q, org, userID, id, history.ChangeCreate, now, journeyRowState{}, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "create journey failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.Header().Set("Location", "/v1/journeys/"+uuidString(row.ID))
		writeJSON(w, r, http.StatusCreated, toJourneyDTO(row, apiaryIDStrings))
	}
}

// unownedApiaryFieldErrors builds one field error per apiaryIDs entry that
// `owned` doesn't confirm belongs to the caller's org — shared by
// createJourney and updateJourney so both report identical field paths
// (apiary_ids[i]) for the identical rejection.
func unownedApiaryFieldErrors(apiaryIDs []uuid.UUID, owned map[string]bool) []problem.FieldError {
	var errs []problem.FieldError
	for i, id := range apiaryIDs {
		if !owned[id.String()] {
			errs = append(errs, problem.FieldError{
				Field:   fmt.Sprintf("apiary_ids[%d]", i),
				Code:    "not_found",
				Message: "apiary_ids entries must refer to an apiary in this organization",
			})
		}
	}
	return errs
}

// respondIdempotentCreateOrConflict handles createJourney's unique_violation
// branch: the id already exists in this org. Same content (name,
// main_activity_type, and the SAME apiary_ids SET regardless of order) ⇒
// 201 with the existing (unchanged) row; different content, or the id
// belongs to a different org (existing row simply not found under org
// scope) ⇒ 409. Mirrors activities'/apiaries' write.go helper of the same
// name/shape.
func respondIdempotentCreateOrConflict(ctx context.Context, w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, org pgtype.UUID, id uuid.UUID, name, mainActivityType string, apiaryIDs []string) {
	pgID := pgtype.UUID{Bytes: id, Valid: true}
	existing, err := q.GetJourney(ctx, sqlcgen.GetJourneyParams{OrganizationID: org, ID: pgID})
	if err != nil {
		problem.Write(w, r, problem.Conflict("a journey with this id already exists"))
		return
	}
	existingApiaryIDs, err := currentApiaryIDs(ctx, q, org, pgID)
	if err != nil {
		problem.Write(w, r, problem.Conflict("a journey with this id already exists"))
		return
	}
	sameApiaryIDs := stringSetsEqual(existingApiaryIDs, apiaryIDs)
	if existing.Name != name || existing.MainActivityType != mainActivityType || existing.Status != StatusOpen || !sameApiaryIDs {
		problem.Write(w, r, problem.Conflict("a journey with this id already exists with different content"))
		return
	}
	writeJSON(w, r, http.StatusCreated, toJourneyDTO(existing, existingApiaryIDs))
}

func updateJourney(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "journeyId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("journey not found"))
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCreateBodyBytes)
		var body journeyUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		apiaryIDs, fieldErrs := validateJourneyFields(body.Name, body.MainActivityType, body.ApiaryIDs)
		if body.Status != nil && !IsKnownStatus(*body.Status) {
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "status", Code: "invalid", Message: fmt.Sprintf("status must be one of %v", []string{StatusOpen, StatusClosed})})
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// Re-verify EVERY submitted apiary_id (full resubmit convention, this
		// package's doc comment) — simpler and still zero-trust, even though
		// it re-checks apiaries already on the plan.
		bearer := r.Header.Get("Authorization")
		owned, err := verifyApiaryIDs(r.Context(), verifier, bearer, apiaryIDs)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		if errs := unownedApiaryFieldErrors(apiaryIDs, owned); len(errs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", errs...))
			return
		}

		pgID := pgtype.UUID{Bytes: id, Valid: true}
		newApiaryIDSet := make(map[string]bool, len(apiaryIDs))
		for _, a := range apiaryIDs {
			newApiaryIDSet[a.String()] = true
		}

		var (
			updated   sqlcgen.JourneysJourney
			want      journeyRowState
			resultIDs []string
		)
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetJourneyForUpdate(r.Context(), sqlcgen.GetJourneyForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("journey not found"))
				return errResponseWritten
			}

			currentItems, err := q.ListJourneyPlanItemsByJourney(r.Context(), sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: org, JourneyID: pgID})
			if err != nil {
				return fmt.Errorf("list journey plan items: %w", err)
			}
			currentApiaryIDs := make([]string, 0, len(currentItems))
			for _, item := range currentItems {
				currentApiaryIDs = append(currentApiaryIDs, uuidString(item.ApiaryID))
			}

			before := journeyRowState{name: current.Name, mainActivityType: current.MainActivityType, status: current.Status, apiaryIDs: sortedStrings(currentApiaryIDs)}

			newStatus := current.Status
			if body.Status != nil {
				newStatus = *body.Status
			}

			now := time.Now().UTC()
			nowTS := pgtype.Timestamptz{Time: now, Valid: true}

			// Diff the plan: remove items whose apiary is no longer requested,
			// add items for newly-requested apiaries — an unaffected apiary's
			// row (and its created_at) is left completely untouched.
			for _, item := range currentItems {
				if !newApiaryIDSet[uuidString(item.ApiaryID)] {
					if _, err := q.SoftDeleteJourneyPlanItem(r.Context(), sqlcgen.SoftDeleteJourneyPlanItemParams{OrganizationID: org, ID: item.ID, DeletedAt: nowTS}); err != nil {
						return fmt.Errorf("remove journey plan item: %w", err)
					}
				}
			}
			currentApiaryIDSet := make(map[string]bool, len(currentItems))
			for _, item := range currentItems {
				currentApiaryIDSet[uuidString(item.ApiaryID)] = true
			}
			for _, apiaryID := range apiaryIDs {
				if currentApiaryIDSet[apiaryID.String()] {
					continue
				}
				if _, err := q.InsertJourneyPlanItem(r.Context(), sqlcgen.InsertJourneyPlanItemParams{
					ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, OrganizationID: org,
					JourneyID: pgID, ApiaryID: pgtype.UUID{Bytes: apiaryID, Valid: true},
				}); err != nil {
					return fmt.Errorf("insert journey plan item: %w", err)
				}
			}

			updated, err = q.UpdateJourney(r.Context(), sqlcgen.UpdateJourneyParams{
				OrganizationID: org, ID: pgID, Name: body.Name, MainActivityType: body.MainActivityType,
				Status: newStatus, UpdatedAt: nowTS,
			})
			if err != nil {
				return fmt.Errorf("update journey: %w", err)
			}

			resultIDs = uuidStrings(apiaryIDs)
			want = journeyRowState{name: body.Name, mainActivityType: body.MainActivityType, status: newStatus, apiaryIDs: sortedStrings(resultIDs)}
			if err := writeJourneyAuditLogTx(r.Context(), q, org, userID, id, history.ChangeUpdate, now, before, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "update journey failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		writeJSON(w, r, http.StatusOK, toJourneyDTO(updated, resultIDs))
	}
}

// deleteJourney handles DELETE /v1/journeys/{id} (FR-JO-4): tombstones the
// row (mirrors activities'/apiaries' deleteActivity/deleteApiary) rather
// than a hard delete, so the PowerSync sync rule's `deleted_at IS NULL`
// filter propagates the delete to every device. Records the delete in
// audit_log (FR-HIS-1). The journey's plan items are deliberately left in
// place — inert, invisible once their parent journey is gone from any query
// that joins through it — mirroring apiaries' own "delete apiary, leave its
// counter rows" convention (apiaries_repository.dart's doc comment).
func deleteJourney(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "journeyId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("journey not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetJourneyForUpdate(r.Context(), sqlcgen.GetJourneyForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("journey not found"))
				return errResponseWritten
			}

			now := time.Now().UTC()
			rowsAffected, err := q.SoftDeleteJourney(r.Context(), sqlcgen.SoftDeleteJourneyParams{
				OrganizationID: org, ID: pgID, DeletedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if err != nil {
				return fmt.Errorf("soft delete journey: %w", err)
			}
			if rowsAffected == 0 {
				problem.Write(w, r, problem.NotFound("journey not found"))
				return errResponseWritten
			}

			apiaryIDs, err := currentApiaryIDs(r.Context(), q, org, pgID)
			if err != nil {
				return fmt.Errorf("list journey plan items: %w", err)
			}
			before := journeyRowState{name: current.Name, mainActivityType: current.MainActivityType, status: current.Status, apiaryIDs: sortedStrings(apiaryIDs)}
			if err := writeJourneyAuditLogTx(r.Context(), q, org, userID, id, history.ChangeDelete, now, before, journeyRowState{}); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "delete journey failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.WriteHeader(http.StatusNoContent)
	}
}

func toJourneyDTO(row sqlcgen.JourneysJourney, apiaryIDs []string) journeyDTO {
	return journeyDTO{
		ID:               uuidString(row.ID),
		OrganizationID:   uuidString(row.OrganizationID),
		Name:             row.Name,
		MainActivityType: row.MainActivityType,
		Status:           row.Status,
		ApiaryIDs:        sortedStrings(apiaryIDs),
		CreatedAt:        row.CreatedAt.Time,
		UpdatedAt:        row.UpdatedAt.Time,
	}
}

// currentApiaryIDs reads a journey's current LIVE plan as a plain string
// slice — shared by both write.go (idempotent-create comparison, delete's
// "before" audit state) and callers that need the wire/audit shape rather
// than the raw sqlcgen rows.
func currentApiaryIDs(ctx context.Context, q *sqlcgen.Queries, org, journeyID pgtype.UUID) ([]string, error) {
	items, err := q.ListJourneyPlanItemsByJourney(ctx, sqlcgen.ListJourneyPlanItemsByJourneyParams{OrganizationID: org, JourneyID: journeyID})
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = append(out, uuidString(item.ApiaryID))
	}
	return out, nil
}

func uuidStrings(ids []uuid.UUID) []string {
	out := make([]string, len(ids))
	for i, id := range ids {
		out[i] = id.String()
	}
	return out
}

// sortedStrings returns a sorted COPY of ss — used everywhere an apiary_ids
// set is projected for history.ComputeChange's diff or an idempotent-content
// comparison, so a resubmission of the identical SET in a different order
// never shows up as a spurious change (reflect.DeepEqual, which
// history.ComputeChange uses, is order-sensitive for slices).
func sortedStrings(ss []string) []string {
	out := make([]string, len(ss))
	copy(out, ss)
	sort.Strings(out)
	return out
}

// stringSetsEqual reports whether a and b contain the same strings,
// regardless of order or duplicates — used by respondIdempotentCreateOrConflict
// to compare a resubmitted apiary_ids list against the stored plan.
func stringSetsEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	sa, sb := sortedStrings(a), sortedStrings(b)
	for i := range sa {
		if sa[i] != sb[i] {
			return false
		}
	}
	return true
}

// journeyRowState is the mutable projection of a journey for history
// diffing AND (via the sync-apply LWW/idempotent-resend compare, sync.go's
// mergeJourneyOp) — mirrors activities' shared activityRowState, serving
// both write.go's REST handlers and sync.go's applyJourneyOp.
type journeyRowState struct {
	name             string
	mainActivityType string
	status           string
	apiaryIDs        []string // always kept sorted (sortedStrings) by every constructor
	deletedAt        pgtype.Timestamptz
}

// fields projects the content columns history.ComputeChange diffs —
// deliberately EXCLUDES deletedAt (mirrors activities' activityRowState.fields):
// writeJourneyAuditLogTx/writeJourneyAuditLog already special-case
// history.ChangeDelete by nulling the "after" field map entirely, so a
// tombstone's own delta never leaks a raw deleted_at timestamp into the
// audit_log.change payload.
func (j journeyRowState) fields() map[string]any {
	return map[string]any{
		"name":               j.name,
		"main_activity_type": j.mainActivityType,
		"status":             j.status,
		"apiary_ids":         j.apiaryIDs,
	}
}

// sameAs reports whether j and other represent identical row content,
// INCLUDING tombstone state — sync.go's applyJourneyOp LWW compare uses this
// to distinguish an idempotent re-send (no domain change, no conflict log
// entry) from a genuine LWW loss.
func (j journeyRowState) sameAs(other journeyRowState) bool {
	if j.name != other.name || j.mainActivityType != other.mainActivityType ||
		j.status != other.status || j.deletedAt.Valid != other.deletedAt.Valid ||
		len(j.apiaryIDs) != len(other.apiaryIDs) {
		return false
	}
	for i := range j.apiaryIDs {
		if j.apiaryIDs[i] != other.apiaryIDs[i] {
			return false
		}
	}
	return true
}

// writeJourneyAuditLogTx appends one history.md §3 row for a REST create/
// update/delete, in the same local transaction as the domain write
// (FR-HIS-1) — the REST-path counterpart of sync.go's writeJourneyAuditLog.
func writeJourneyAuditLogTx(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, entityID uuid.UUID, changeType string, occurredAt time.Time, before, after journeyRowState) error {
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
		return fmt.Errorf("compute journey change: %w", err)
	}
	changeJSON, err := json.Marshal(change)
	if err != nil {
		return err
	}
	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeJourney,
		EntityID:       pgtype.UUID{Bytes: entityID, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: occurredAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}
