// Package api (this file) — the client-facing REST create route (POST
// /v1/activities, #39/FR-AC-2). Like apiaries' write.go (see its own doc
// comment), this serves **online-only/direct callers** (the Admin App,
// scripts, tests); the field PWA creates activities through the local-first
// sync path instead (sync.go's InternalSyncRouter), per walking-skeleton.md
// §4.4. Both paths write the same activities.activities table and must
// apply the same validation, tenancy and history-recording rules — see
// validateActivityCreate below and sync.go's validateActivityOp, and
// writeActivityAuditLogTx here and sync.go's writeActivityAuditLog.
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
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/activities/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// maxCreateBodyBytes caps the raw request body for POST /v1/activities — an
// activity payload is a handful of known keys, notes capped at
// maxNotesLength chars (types.go) — via http.MaxBytesReader, mirroring
// validate.go's maxValidateBodyBytes.
const maxCreateBodyBytes = 256 << 10 // 256 KiB

// activityCreateRequest is the POST /v1/activities request body. id is
// client-supplied (offline-generatable UUID, api-contracts.md §4, matching
// apiaries' apiaryCreateRequest.ID convention) — the natural idempotency
// anchor for a re-sent create. apiary_id is a CROSS-SERVICE reference
// (apiaries_client.go's doc comment) — verified against the caller's org
// before anything is written. performed_by is deliberately NOT a request
// field: FR-TEN-2 requires it be derived server-side from the authenticated
// caller's own claims (requireOrg), never accepted from the client — a
// client-supplied actor would let any org member attribute an activity to
// someone else. journey_id (D-21) is optional and unused by any UI yet
// (#46/M4) — accepted now so no follow-up contract change is needed then.
type activityCreateRequest struct {
	ID         string          `json:"id"`
	ApiaryID   string          `json:"apiary_id"`
	Type       string          `json:"type"`
	OccurredAt string          `json:"occurred_at"`
	Attributes json.RawMessage `json:"attributes"`
	JourneyID  *string         `json:"journey_id"`
}

// activityUpdateRequest is the PATCH /v1/activities/{id} request body
// (#40/FR-AC-3). Unlike apiaries' apiaryUpdateRequest (a true partial
// PATCH with per-field presence tracking), activities' edit form always
// resubmits the COMPLETE current state (add_activity_screen.dart reuses
// the exact same adaptive form for edit, pre-filled — every save rebuilds
// the whole attributes map from the form's current controls, never a
// sparse diff) — so type/occurred_at/attributes are all REQUIRED here,
// mirroring activityCreateRequest's own shape minus id. apiary_id is the
// one genuinely optional field: the edit UI never changes it, but the
// wire contract supports re-pointing an activity at a different apiary of
// the SAME organization — when present, it is re-verified via the same
// cross-service ownership check createActivity uses (FR-TEN-2 carry-over,
// #40's own review note); when absent, the activity's current apiary_id is
// left untouched and no ownership call is made at all.
type activityUpdateRequest struct {
	ApiaryID   *string         `json:"apiary_id"`
	Type       string          `json:"type"`
	OccurredAt string          `json:"occurred_at"`
	Attributes json.RawMessage `json:"attributes"`
}

// activityDTO is the client-facing activity shape.
type activityDTO struct {
	ID             string         `json:"id"`
	OrganizationID string         `json:"organization_id"`
	ApiaryID       string         `json:"apiary_id"`
	PerformedBy    string         `json:"performed_by"`
	JourneyID      *string        `json:"journey_id,omitempty"`
	Type           string         `json:"type"`
	OccurredAt     string         `json:"occurred_at"`
	Attributes     map[string]any `json:"attributes"`
	CreatedAt      time.Time      `json:"created_at"`
	UpdatedAt      time.Time      `json:"updated_at"`
}

// Router returns the client-facing /v1/activities surface: the REST create
// route (#39/FR-AC-2) plus edit (#40/FR-AC-3), delete (#41/FR-AC-4) and the
// per-activity history read (#60/FR-HIS-1, history.go). List is a later
// EPIC-03 story (#42/#43), following #38's own scope-split precedent —
// history.go's read is scoped to one entity's timeline, not a list surface.
// journeyVerifier (#46) is only consulted by create — journey_id is immutable
// after creation (updateActivity's own doc comment), so edit/delete never need it.
func Router(pool *pgxpool.Pool, verifier *ApiaryVerifier, journeyVerifier *JourneyVerifier) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/{activityId}/history", getActivityHistory(q))
	r.Post("/", createActivity(pool, verifier, journeyVerifier))
	r.Patch("/{activityId}", updateActivity(pool, verifier))
	r.Delete("/{activityId}", deleteActivity(pool))
	return r
}

func createActivity(pool *pgxpool.Pool, verifier *ApiaryVerifier, journeyVerifier *JourneyVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCreateBodyBytes)
		var body activityCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		id, apiaryID, journeyID, attrs, fieldErrs := validateActivityCreate(body)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// CRITICAL tenancy guard (carry-over from #38's review, mirroring
		// #284's "fix(apiaries): close cross-tenant IDOR on counter sync"):
		// apiary_id must belong to the CALLER'S organization, verified via
		// the owning service (apiaries_client.go), BEFORE any row is
		// inserted — never trust the client-supplied id at face value.
		belongs, err := verifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), apiaryID.String())
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		if !belongs {
			// Unknown/foreign apiary_id — 404, indistinguishable from a
			// truly-nonexistent apiary (ADR-0002 scope-hiding, same
			// convention apiaries' own getApiary/getApiaryDistance use).
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
				problem.FieldError{Field: "apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary in this organization"}))
			return
		}

		// CRITICAL tenancy guard (#46 review finding): journey_id, like
		// apiary_id above, is a cross-service reference — verify it belongs
		// to the CALLER'S organization via the owning service
		// (journeys_client.go) BEFORE any row is inserted. Only runs when
		// the request actually carries a journey_id (the common case, an
		// activity logged with no journey attached, makes no upstream call
		// at all).
		if journeyID != nil {
			journeyBelongs, err := journeyVerifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), journeyID.String())
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify journey ownership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			if !journeyBelongs {
				// Unknown/foreign journey_id — 404, indistinguishable from a
				// truly-nonexistent journey (ADR-0002 scope-hiding, same
				// convention journeys' own getJourney uses).
				problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
					problem.FieldError{Field: "journey_id", Code: "not_found", Message: "journey_id does not refer to a journey in this organization"}))
				return
			}
		}

		performedBy, err := uuid.Parse(userID)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "createActivity: userID claim is not a valid UUID", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		attrsJSON, err := json.Marshal(attrs)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "marshal activity attributes failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		occurredAt, _ := time.Parse(dateLayout, body.OccurredAt) // format already validated
		now := time.Now().UTC()
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		var row sqlcgen.ActivitiesActivity
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			var err error
			row, err = q.InsertActivity(r.Context(), sqlcgen.InsertActivityParams{
				ID:             pgID,
				OrganizationID: org,
				ApiaryID:       pgtype.UUID{Bytes: apiaryID, Valid: true},
				PerformedBy:    pgtype.UUID{Bytes: performedBy, Valid: true},
				JourneyID:      journeyIDParam(journeyID),
				Type:           body.Type,
				OccurredAt:     pgtype.Date{Time: occurredAt, Valid: true},
				Attributes:     attrsJSON,
				UpdatedAt:      pgtype.Timestamptz{Time: now, Valid: true},
			})
			if isUniqueViolation(err) {
				// Idempotency (the client-generated id is the natural
				// anchor, same convention as apiaries' createApiary): a
				// re-sent create with the same id and the same content
				// returns the original result unchanged; a genuinely
				// different payload reusing the same id is a real conflict.
				respondIdempotentCreateOrConflict(r.Context(), w, r, sqlcgen.New(pool), org, id, apiaryID, body.Type, body.OccurredAt, attrs)
				return errResponseWritten
			}
			if err != nil {
				return fmt.Errorf("insert activity: %w", err)
			}

			want := activityRowState{apiaryID: apiaryID.String(), typ: body.Type, occurredAt: body.OccurredAt, attributes: attrs, journeyID: journeyIDStringFromPtr(journeyID)}
			if err := writeActivityAuditLogTx(r.Context(), q, org, userID, id, history.ChangeCreate, now, activityRowState{}, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "create activity failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.Header().Set("Location", "/v1/activities/"+uuidString(row.ID))
		writeJSON(w, r, http.StatusCreated, toActivityDTO(row))
	}
}

// updateActivity handles PATCH /v1/activities/{id} (#40/FR-AC-3): re-runs
// ValidateActivity server-side (same rules a create must pass), re-verifies
// apiary ownership via the same cross-service ApiaryVerifier createActivity
// uses — but ONLY when the request actually carries a new apiary_id
// (activityUpdateRequest's doc comment) — records the edit in audit_log
// (FR-HIS-1), and never touches performed_by/journey_id.
func updateActivity(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "activityId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("activity not found"))
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCreateBodyBytes)
		var body activityUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		newApiaryID, attrs, fieldErrs := validateActivityUpdate(body)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// Ownership re-verify (CRITICAL, FR-TEN-2 carry-over from createActivity):
		// only when the request actually carries a apiary_id — the common case
		// (the edit form never changes it) makes no cross-service call at all,
		// exactly like sync.go's resolveApiaryOwnership only resolves apiary_ids
		// that are actually present in a batch op's data.
		if newApiaryID != nil {
			belongs, err := verifier.BelongsToOrg(r.Context(), r.Header.Get("Authorization"), newApiaryID.String())
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "verify apiary ownership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			if !belongs {
				problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
					problem.FieldError{Field: "apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary in this organization"}))
				return
			}
		}

		pgID := pgtype.UUID{Bytes: id, Valid: true}
		attrsJSON, err := json.Marshal(attrs)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "marshal activity attributes failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		occurredAt, _ := time.Parse(dateLayout, body.OccurredAt) // format already validated

		var (
			updated sqlcgen.ActivitiesActivity
			want    activityRowState
		)
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetActivityForUpdate(r.Context(), sqlcgen.GetActivityForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("activity not found"))
				return errResponseWritten
			}

			var currentAttrs map[string]any
			_ = json.Unmarshal(current.Attributes, &currentAttrs)
			// journeyID (#387): REST's updateActivity never CHANGES journey_id
			// (still immutable on this path by design — #387's own
			// asymmetry note), but before/want must still reflect the row's
			// TRUE current link, not a blank default, so the audit_log
			// baseline this handler writes stays accurate.
			before := activityRowState{apiaryID: uuidString(current.ApiaryID), typ: current.Type, occurredAt: current.OccurredAt.Time.Format(dateLayout), attributes: currentAttrs, journeyID: journeyIDString(current.JourneyID)}

			apiaryIDParam := current.ApiaryID
			want = before
			want.typ = body.Type
			want.occurredAt = body.OccurredAt
			want.attributes = attrs
			if newApiaryID != nil {
				apiaryIDParam = pgtype.UUID{Bytes: *newApiaryID, Valid: true}
				want.apiaryID = newApiaryID.String()
			}

			now := time.Now().UTC()
			var updateErr error
			updated, updateErr = q.UpdateActivity(r.Context(), sqlcgen.UpdateActivityParams{
				OrganizationID: org, ID: pgID,
				ApiaryID:   apiaryIDParam,
				Type:       body.Type,
				OccurredAt: pgtype.Date{Time: occurredAt, Valid: true},
				Attributes: attrsJSON,
				UpdatedAt:  pgtype.Timestamptz{Time: now, Valid: true},
			})
			if updateErr != nil {
				return fmt.Errorf("update activity: %w", updateErr)
			}

			if err := writeActivityAuditLogTx(r.Context(), q, org, userID, id, history.ChangeUpdate, now, before, want); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "update activity failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		writeJSON(w, r, http.StatusOK, toActivityDTO(updated))
	}
}

// validateActivityUpdate validates an activityUpdateRequest the same way
// validateActivityCreate validates a create — occurred_at format, and (via
// ValidateActivity) the selected type's own attribute schema — minus the
// id check (the id comes from the URL, not the body) and with apiary_id
// OPTIONAL (activityUpdateRequest's doc comment) rather than required.
func validateActivityUpdate(body activityUpdateRequest) (apiaryID *uuid.UUID, attrs map[string]any, errs []problem.FieldError) {
	if body.ApiaryID != nil {
		parsed, err := uuid.Parse(*body.ApiaryID)
		if err != nil {
			errs = append(errs, problem.FieldError{Field: "apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
		} else {
			apiaryID = &parsed
		}
	}

	switch {
	case strings.TrimSpace(body.OccurredAt) == "":
		errs = append(errs, problem.FieldError{Field: "occurred_at", Code: "required", Message: "occurred_at is required"})
	default:
		if _, err := time.Parse(dateLayout, body.OccurredAt); err != nil {
			errs = append(errs, problem.FieldError{Field: "occurred_at", Code: "invalid", Message: "occurred_at must be a YYYY-MM-DD date"})
		}
	}

	attrs = map[string]any{}
	attrsOK := true
	if len(body.Attributes) > 0 {
		if err := json.Unmarshal(body.Attributes, &attrs); err != nil || attrs == nil {
			errs = append(errs, problem.FieldError{Field: "attributes", Code: "invalid", Message: "attributes must be a JSON object"})
			attrsOK = false
		}
	}

	switch {
	case strings.TrimSpace(body.Type) == "":
		errs = append(errs, problem.FieldError{Field: "type", Code: "required", Message: "type is required"})
	case attrsOK:
		errs = append(errs, ValidateActivity(body.Type, attrs)...)
	}

	return apiaryID, attrs, errs
}

// deleteActivity handles DELETE /v1/activities/{id} (#41/FR-AC-4):
// tombstones the row (deleted_at, mirroring apiaries' deleteApiary) rather
// than a hard delete, so the PowerSync sync rule's `deleted_at IS NULL`
// filter (infra/helm/beekeepingit/charts/powersync/values.yaml) propagates
// the delete to every device on their next sync — the client's local
// [rejectedOpsTable]/schema carries no deleted_at column of its own; the
// row simply leaves each device's result set. Records the delete in
// audit_log (FR-HIS-1). Unlike updateActivity, delete never needs the
// ApiaryVerifier — it doesn't touch apiary_id, so there is no ownership
// question to re-check (the row's own organization_id, already enforced by
// GetActivityForUpdate's WHERE clause, is the only tenancy fact that
// matters for removing an existing row).
func deleteActivity(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "activityId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("activity not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			current, err := q.GetActivityForUpdate(r.Context(), sqlcgen.GetActivityForUpdateParams{OrganizationID: org, ID: pgID})
			if err != nil || current.DeletedAt.Valid {
				problem.Write(w, r, problem.NotFound("activity not found"))
				return errResponseWritten
			}

			now := time.Now().UTC()
			rowsAffected, err := q.SoftDeleteActivity(r.Context(), sqlcgen.SoftDeleteActivityParams{
				OrganizationID: org, ID: pgID, DeletedAt: pgtype.Timestamptz{Time: now, Valid: true},
			})
			if err != nil {
				return fmt.Errorf("soft delete activity: %w", err)
			}
			if rowsAffected == 0 {
				problem.Write(w, r, problem.NotFound("activity not found"))
				return errResponseWritten
			}

			var currentAttrs map[string]any
			_ = json.Unmarshal(current.Attributes, &currentAttrs)
			before := activityRowState{apiaryID: uuidString(current.ApiaryID), typ: current.Type, occurredAt: current.OccurredAt.Time.Format(dateLayout), attributes: currentAttrs, journeyID: journeyIDString(current.JourneyID)}
			if err := writeActivityAuditLogTx(r.Context(), q, org, userID, id, history.ChangeDelete, now, before, activityRowState{}); err != nil {
				return fmt.Errorf("write audit log: %w", err)
			}
			return nil
		})
		if err != nil {
			if !errors.Is(err, errResponseWritten) {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "delete activity failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
			}
			return
		}

		w.WriteHeader(http.StatusNoContent)
	}
}

// respondIdempotentCreateOrConflict handles createActivity's unique_violation
// branch: the id already exists in this org. Same content ⇒ 201 with the
// existing (unchanged) row; different content, or the id belongs to a
// different org (existing row simply not found under org scope) ⇒ 409.
// Mirrors apiaries' write.go helper of the same name/shape.
func respondIdempotentCreateOrConflict(ctx context.Context, w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, org pgtype.UUID, id, apiaryID uuid.UUID, activityType, occurredAt string, attrs map[string]any) {
	existing, err := q.GetActivity(ctx, sqlcgen.GetActivityParams{OrganizationID: org, ID: pgtype.UUID{Bytes: id, Valid: true}})
	if err != nil {
		problem.Write(w, r, problem.Conflict("an activity with this id already exists"))
		return
	}
	var existingAttrs map[string]any
	_ = json.Unmarshal(existing.Attributes, &existingAttrs)
	sameApiary := uuidString(existing.ApiaryID) == apiaryID.String()
	sameType := existing.Type == activityType
	sameOccurredAt := existing.OccurredAt.Time.Format(dateLayout) == occurredAt
	sameAttrs := attributesEqual(existingAttrs, attrs)
	if !sameApiary || !sameType || !sameOccurredAt || !sameAttrs {
		problem.Write(w, r, problem.Conflict("an activity with this id already exists with different content"))
		return
	}
	writeJSON(w, r, http.StatusCreated, toActivityDTO(existing))
}

func toActivityDTO(row sqlcgen.ActivitiesActivity) activityDTO {
	var attrs map[string]any
	_ = json.Unmarshal(row.Attributes, &attrs)
	return activityDTO{
		ID:             uuidString(row.ID),
		OrganizationID: uuidString(row.OrganizationID),
		ApiaryID:       uuidString(row.ApiaryID),
		PerformedBy:    uuidString(row.PerformedBy),
		JourneyID:      journeyIDPtr(row.JourneyID),
		Type:           row.Type,
		OccurredAt:     row.OccurredAt.Time.Format(dateLayout),
		Attributes:     attrs,
		CreatedAt:      row.CreatedAt.Time,
		UpdatedAt:      row.UpdatedAt.Time,
	}
}

// validateActivityCreate validates body's shape (id/apiary_id UUIDs,
// occurred_at format, journey_id UUID if present) and — via ValidateActivity
// — the selected type's own attribute schema. Field-shape checks run first
// so a malformed id/apiary_id never reaches ValidateActivity with a
// nonsensical type.
func validateActivityCreate(body activityCreateRequest) (id, apiaryID uuid.UUID, journeyID *uuid.UUID, attrs map[string]any, errs []problem.FieldError) {
	id, err := uuid.Parse(body.ID)
	if err != nil {
		errs = append(errs, problem.FieldError{Field: "id", Code: "invalid", Message: "id must be a UUID"})
	}
	apiaryID, err = uuid.Parse(body.ApiaryID)
	if err != nil {
		errs = append(errs, problem.FieldError{Field: "apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
	}
	if body.JourneyID != nil {
		jid, err := uuid.Parse(*body.JourneyID)
		if err != nil {
			errs = append(errs, problem.FieldError{Field: "journey_id", Code: "invalid", Message: "journey_id must be a UUID"})
		} else {
			journeyID = &jid
		}
	}

	switch {
	case strings.TrimSpace(body.OccurredAt) == "":
		errs = append(errs, problem.FieldError{Field: "occurred_at", Code: "required", Message: "occurred_at is required"})
	default:
		if _, err := time.Parse(dateLayout, body.OccurredAt); err != nil {
			errs = append(errs, problem.FieldError{Field: "occurred_at", Code: "invalid", Message: "occurred_at must be a YYYY-MM-DD date"})
		}
	}

	attrs = map[string]any{}
	attrsOK := true
	if len(body.Attributes) > 0 {
		if err := json.Unmarshal(body.Attributes, &attrs); err != nil || attrs == nil {
			errs = append(errs, problem.FieldError{Field: "attributes", Code: "invalid", Message: "attributes must be a JSON object"})
			attrsOK = false
		}
	}

	switch {
	case strings.TrimSpace(body.Type) == "":
		errs = append(errs, problem.FieldError{Field: "type", Code: "required", Message: "type is required"})
	case attrsOK:
		errs = append(errs, ValidateActivity(body.Type, attrs)...)
	}

	return id, apiaryID, journeyID, attrs, errs
}

func journeyIDParam(id *uuid.UUID) pgtype.UUID {
	if id == nil {
		return pgtype.UUID{}
	}
	return pgtype.UUID{Bytes: *id, Valid: true}
}

func journeyIDPtr(id pgtype.UUID) *string {
	if !id.Valid {
		return nil
	}
	s := uuidString(id)
	return &s
}

// journeyIDString converts a nullable pgtype.UUID journey_id column to the
// activityRowState/audit convention (#387): "" means no journey attached,
// otherwise the canonical UUID string.
func journeyIDString(id pgtype.UUID) string {
	if !id.Valid {
		return ""
	}
	return uuidString(id)
}

// journeyIDStringFromPtr is journeyIDString's *uuid.UUID counterpart (#387),
// for call sites that already parsed a request's journey_id into a
// *uuid.UUID (createActivity, applyActivityOp's materializing branch)
// rather than reading it back off a stored row.
func journeyIDStringFromPtr(id *uuid.UUID) string {
	if id == nil {
		return ""
	}
	return id.String()
}

// journeyIDParamFromString is journeyIDString's inverse (#387) — used by
// applyActivityOp's LWW-update branch, where mergeActivityOp has already
// computed the desired activityRowState.journeyID as a plain string and it
// must be re-encoded as the pgtype.UUID param UpdateActivitySync expects.
// "" (no journey) maps to an invalid/NULL pgtype.UUID, exactly like
// journeyIDParam's own nil-*uuid.UUID case.
func journeyIDParamFromString(s string) (pgtype.UUID, error) {
	if s == "" {
		return pgtype.UUID{}, nil
	}
	parsed, err := uuid.Parse(s)
	if err != nil {
		return pgtype.UUID{}, err
	}
	return pgtype.UUID{Bytes: parsed, Valid: true}, nil
}

// attributesEqual compares two decoded attribute maps for the idempotent-
// replay content check — a shallow-enough comparison since every attribute
// value is a JSON scalar (string/number/bool), never a nested
// object/array, per types.go's attrKind set.
func attributesEqual(a, b map[string]any) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		bv, ok := b[k]
		if !ok || fmt.Sprintf("%v", v) != fmt.Sprintf("%v", bv) {
			return false
		}
	}
	return true
}

// activityRowState is the mutable projection of an activity for history
// diffing AND (via deletedAt/sameAs, #40/#41) the sync-apply LWW
// idempotent-resend/conflict compare — mirrors apiaries' restRowState/
// rowState shape (there, split into two types because of apiaries'
// location/hive-counter complexity; activities has neither, so one shared
// type serves both write.go's REST handlers and sync.go's applyActivityOp,
// same as it already did for #39's create-only scope).
type activityRowState struct {
	apiaryID   string
	typ        string
	occurredAt string
	attributes map[string]any
	// journeyID (#387): "" means no journey attached, otherwise the
	// canonical UUID string — participates in LWW compare/audit/conflict
	// like every other mutable column, closing the silent-drop gap this
	// issue's own warning describes.
	journeyID string
	deletedAt pgtype.Timestamptz
}

// fields projects the content columns history.ComputeChange diffs —
// deliberately EXCLUDES deletedAt (mirrors apiaries' rowState.fields()):
// writeActivityAuditLogTx/writeActivityAuditLog already special-case
// history.ChangeDelete by nulling the "after" field map entirely, so a
// tombstone's own delta never leaks a raw deleted_at timestamp into the
// audit_log.change payload.
func (a activityRowState) fields() map[string]any {
	return map[string]any{
		"apiary_id":   a.apiaryID,
		"type":        a.typ,
		"occurred_at": a.occurredAt,
		"attributes":  a.attributes,
		"journey_id":  a.journeyID,
	}
}

// sameAs reports whether a and b represent the identical row content,
// INCLUDING tombstone state — sync.go's applyActivityOp LWW compare (#40/
// #41/#387, mirrors apiaries' rowState.sameAs) uses this to distinguish an
// idempotent re-send (no domain change, no conflict log entry) from a
// genuine LWW loss.
func (a activityRowState) sameAs(b activityRowState) bool {
	return a.apiaryID == b.apiaryID && a.typ == b.typ && a.occurredAt == b.occurredAt &&
		attributesEqual(a.attributes, b.attributes) && a.journeyID == b.journeyID && a.deletedAt.Valid == b.deletedAt.Valid
}

// writeActivityAuditLogTx appends one history.md §3 row for a REST create,
// in the same local transaction as the domain write (FR-HIS-1) — the
// REST-path counterpart of sync.go's writeActivityAuditLog.
func writeActivityAuditLogTx(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, entityID uuid.UUID, changeType string, occurredAt time.Time, before, after activityRowState) error {
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
		return fmt.Errorf("compute activity change: %w", err)
	}
	changeJSON, err := json.Marshal(change)
	if err != nil {
		return err
	}
	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeActivity,
		EntityID:       pgtype.UUID{Bytes: entityID, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: occurredAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// parseActor resolves userID (the caller's resolved user id) to the
// nullable pgtype.UUID audit_log's actor_user_id column expects. Mirrors
// apiaries/api/sync.go's helper of the same name/purpose.
func parseActor(ctx context.Context, userID string) pgtype.UUID {
	u, err := uuid.Parse(userID)
	if err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "parseActor: userID is not a valid UUID; audit actor will be recorded as NULL", slog.Any("error", err))
		return pgtype.UUID{Valid: false}
	}
	return pgtype.UUID{Bytes: u, Valid: true}
}
