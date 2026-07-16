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

// Router returns the client-facing /v1/activities surface: today just the
// REST create route (#39/FR-AC-2) — edit/delete/list are later EPIC-03
// stories (#40/#41/#42/#43), following #38's own scope-split precedent.
func Router(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/", createActivity(pool, verifier))
	return r
}

func createActivity(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.HandlerFunc {
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

			want := activityRowState{apiaryID: apiaryID.String(), typ: body.Type, occurredAt: body.OccurredAt, attributes: attrs}
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
// diffing — mirrors apiaries' restRowState/rowState shape.
type activityRowState struct {
	apiaryID   string
	typ        string
	occurredAt string
	attributes map[string]any
}

func (a activityRowState) fields() map[string]any {
	return map[string]any{
		"apiary_id":   a.apiaryID,
		"type":        a.typ,
		"occurred_at": a.occurredAt,
		"attributes":  a.attributes,
	}
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
