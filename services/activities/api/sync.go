// Package api (this file) — the internal sync validate/apply endpoints
// (#39, FR-OF-1/Q-SYNC, sync.md §5.2/§6) the write-back coordinator
// (services/sync) calls so creating an activity offline (queued locally via
// PowerSync) reconciles on sync, exactly like apiaries' own sync.go. Scope
// is CREATE only, matching #39's AC ("add activity") — edit/delete
// (#40/#41) extend this file's Op/validateActivityOp/applyActivityOp the
// same way apiaries' sync.go grew from create-only to full CRUD, following
// #38's scope-split precedent (main.go's doc comment) rather than building
// unused surface now.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/activities/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// maxBatchOps/maxSyncBatchBodyBytes mirror apiaries/api/sync.go's identical
// caps (same rationale: applyBatch holds this whole batch's writes in one
// local transaction).
const (
	maxBatchOps           = 500
	maxSyncBatchBodyBytes = 8 << 20 // 8 MiB
)

// Op is one CRUD op in a client sync batch — the activities-service subset
// of the wire shape services/sync/api/coordinator.go fans out
// (entity_type "activity"). Mirrors apiaries/api/sync.go's Op.
type Op struct {
	Op         string          `json:"op"`          // put (create-only, #39 scope)
	EntityType string          `json:"entity_type"` // activity
	ID         string          `json:"id"`
	Data       json.RawMessage `json:"data"`
	UpdatedAt  time.Time       `json:"updated_at"` // device time; LWW comparator
}

// Batch is one client transaction — the body of validate/apply.
type Batch struct {
	Ops []Op `json:"ops"`
}

// activityData is the sync wire shape for an entityTypeActivity op's `data`
// — the same {apiary_id, type, occurred_at, attributes, journey_id} shape
// activityCreateRequest carries over REST (write.go), since both paths must
// accept identical content (write.go's package doc comment). performed_by
// is deliberately absent — FR-TEN-2 derives it server-side from the
// caller's claims, never the client, on both paths.
type activityData struct {
	ApiaryID   *string         `json:"apiary_id"`
	Type       *string         `json:"type"`
	OccurredAt *string         `json:"occurred_at"`
	Attributes json.RawMessage `json:"attributes"`
	JourneyID  *string         `json:"journey_id"`
}

// Per-op apply outcomes (sync.md §5.2), mirroring apiaries.
const (
	resultApplied    = "applied"
	resultSuperseded = "superseded"
)

// OpResult is the per-op result the coordinator relays to the client.
type OpResult struct {
	ID     string `json:"id"`
	Op     string `json:"op"`
	Result string `json:"result"`
}

// ApplyResponse is the apply endpoint's body.
type ApplyResponse struct {
	Results []OpResult `json:"results"`
}

// InternalSyncRouter returns the internal sync validate/apply routes,
// following the URL convention services/sync/api/coordinator.go's
// Coordinator already expects for every owning service
// ("{serviceURL}/internal/sync/validate"/"/apply"). Mount under
// "/internal/sync" behind the OIDC authn + org-resolver middleware.
func InternalSyncRouter(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/validate", validateActivityBatch(verifier))
	r.Post("/apply", applyActivityBatch(pool, verifier))
	return r
}

func checkBatchSize(w http.ResponseWriter, r *http.Request, batch Batch) bool {
	if len(batch.Ops) <= maxBatchOps {
		return true
	}
	problem.Write(w, r, problem.ValidationFailed("batch too large",
		problem.FieldError{
			Field:   "ops",
			Code:    "too_many",
			Message: fmt.Sprintf("batch must contain at most %d ops (got %d)", maxBatchOps, len(batch.Ops)),
		}))
	return false
}

// validateActivityBatch dry-runs every op against the same rules
// applyActivityOp enforces, INCLUDING the cross-org apiary_id ownership
// check (mirroring how apiaries' own validateBatch is a pure structural
// check with no DB/upstream call — but activities' tenancy guard lives
// behind an HTTP call, not a local query, so this validate pass makes that
// same call too, keeping validate-then-apply symmetric with the REST path).
func validateActivityBatch(verifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, _, ok := requireOrg(w, r); !ok {
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxSyncBatchBodyBytes)
		var batch Batch
		if err := json.NewDecoder(r.Body).Decode(&batch); err != nil {
			problem.Write(w, r, problem.ValidationFailed("malformed sync batch"))
			return
		}
		if !checkBatchSize(w, r, batch) {
			return
		}

		bearer := r.Header.Get("Authorization")
		var fieldErrs []problem.FieldError
		for i, op := range batch.Ops {
			errs, err := validateActivityOp(r.Context(), verifier, bearer, i, op)
			if err != nil {
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "validate activity batch: verify apiary ownership failed", slog.Any("error", err))
				problem.Write(w, r, problem.Internal())
				return
			}
			fieldErrs = append(fieldErrs, errs...)
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more ops are invalid", fieldErrs...))
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]bool{"valid": true})
	}
}

// validateActivityOp validates one op's shape/attribute-schema, and — when
// those pass — the cross-org apiary_id ownership guard (CRITICAL, same
// rationale as write.go's createActivity). Returns a transport/upstream
// error separately from field errors so the caller can 500 rather than
// mis-report an outage as "your data is invalid".
func validateActivityOp(ctx context.Context, verifier *ApiaryVerifier, bearer string, i int, op Op) ([]problem.FieldError, error) {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	if op.Op != "put" {
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put (activities support create-only sync in this version)"})
	}
	if op.EntityType != entityTypeActivity {
		errs = append(errs, problem.FieldError{Field: prefix + ".entity_type", Code: "invalid", Message: "entity_type must be activity"})
	}
	if _, err := uuid.Parse(op.ID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".id", Code: "invalid", Message: "id must be a UUID"})
	}
	if op.UpdatedAt.IsZero() {
		errs = append(errs, problem.FieldError{Field: prefix + ".updated_at", Code: "required", Message: "updated_at is required"})
	}

	var data activityData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs, nil
		}
	}

	apiaryID := ""
	if data.ApiaryID == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "required", Message: "apiary_id is required"})
	} else if _, err := uuid.Parse(*data.ApiaryID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
	} else {
		apiaryID = *data.ApiaryID
	}

	if data.OccurredAt == nil || *data.OccurredAt == "" {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.occurred_at", Code: "required", Message: "occurred_at is required"})
	} else if _, err := time.Parse(dateLayout, *data.OccurredAt); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.occurred_at", Code: "invalid", Message: "occurred_at must be a YYYY-MM-DD date"})
	}

	attrs := map[string]any{}
	attrsOK := true
	if len(data.Attributes) > 0 {
		if err := json.Unmarshal(data.Attributes, &attrs); err != nil || attrs == nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.attributes", Code: "invalid", Message: "attributes must be a JSON object"})
			attrsOK = false
		}
	}
	if data.Type == nil || *data.Type == "" {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.type", Code: "required", Message: "type is required"})
	} else if attrsOK {
		for _, e := range ValidateActivity(*data.Type, attrs) {
			errs = append(errs, problem.FieldError{Field: prefix + ".data." + e.Field, Code: e.Code, Message: e.Message})
		}
	}
	if data.JourneyID != nil {
		if _, err := uuid.Parse(*data.JourneyID); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.journey_id", Code: "invalid", Message: "journey_id must be a UUID"})
		}
	}

	// Only make the cross-service ownership call once the op is otherwise
	// well-formed — an apiary_id that never parsed has nothing to verify.
	if apiaryID != "" {
		belongs, err := verifier.BelongsToOrg(ctx, bearer, apiaryID)
		if err != nil {
			return nil, err
		}
		if !belongs {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary in this organization"})
		}
	}

	return errs, nil
}

// applyActivityBatch applies the batch in one local transaction (sync.md
// §5.2/§6.2 "apply" phase — validate-all already ran, so this mostly
// re-derives what it needs rather than re-validating from scratch, same as
// apiaries' applyBatch/applyOp split).
func applyActivityBatch(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, userID, ok := requireOrg(w, r)
		if !ok {
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxSyncBatchBodyBytes)
		var batch Batch
		if err := json.NewDecoder(r.Body).Decode(&batch); err != nil {
			problem.Write(w, r, problem.ValidationFailed("malformed sync batch"))
			return
		}
		if !checkBatchSize(w, r, batch) {
			return
		}

		bearer := r.Header.Get("Authorization")
		var results []OpResult
		err := withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			results = make([]OpResult, 0, len(batch.Ops))
			for _, op := range batch.Ops {
				res, err := applyActivityOp(r.Context(), q, verifier, bearer, org, userID, op)
				if err != nil {
					return err
				}
				results = append(results, res)
			}
			return nil
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply activity sync batch failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		writeJSON(w, r, http.StatusOK, ApplyResponse{Results: results})
	}
}

// applyActivityOp applies one create-only op (#39 scope): verifies the
// apiary_id ownership guard again (zero-trust re-check — validate and apply
// are separate requests, sync.md §6.2), then either inserts a brand-new row
// or, for a retried id, compares content for an idempotent no-op vs a
// content conflict (logged, server wins — there is no edit path yet for a
// genuinely different resend to legitimately win via LWW).
func applyActivityOp(ctx context.Context, q *sqlcgen.Queries, verifier *ApiaryVerifier, bearer string, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}

	var data activityData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}
	// validateActivityOp already guarantees these are well-formed by the
	// time apply runs (validate-first, sync.md §6.2).
	apiaryID, err := uuid.Parse(*data.ApiaryID)
	if err != nil {
		return OpResult{}, err
	}

	// Tenancy guard (FR-TEN-2, CRITICAL — re-checked here too, not just in
	// validate: apply is a separate request and must never trust that an
	// earlier validate call for the same op actually ran, mirrors
	// applyCounterOp's own "re-check, don't just rely on validateOp" note in
	// apiaries/api/sync.go).
	belongs, err := verifier.BelongsToOrg(ctx, bearer, apiaryID.String())
	if err != nil {
		return OpResult{}, err
	}
	if !belongs {
		// Unknown/foreign apiary_id — no-op (mirrors applyCounterOp's own
		// "missing row ⇒ nothing to do" convention), not a distinguishable
		// error (ADR-0002 scope-hiding).
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	attrs := map[string]any{}
	if len(data.Attributes) > 0 {
		_ = json.Unmarshal(data.Attributes, &attrs)
	}
	attrsJSON, err := json.Marshal(attrs)
	if err != nil {
		return OpResult{}, err
	}
	occurredAt, err := time.Parse(dateLayout, *data.OccurredAt)
	if err != nil {
		return OpResult{}, err
	}
	var journeyID *uuid.UUID
	if data.JourneyID != nil {
		jid, err := uuid.Parse(*data.JourneyID)
		if err != nil {
			return OpResult{}, err
		}
		journeyID = &jid
	}
	performedBy, err := uuid.Parse(userID)
	if err != nil {
		return OpResult{}, err
	}
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	existing, err := q.GetActivity(ctx, sqlcgen.GetActivityParams{OrganizationID: org, ID: pgID})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	if missing {
		if _, err := q.InsertActivity(ctx, sqlcgen.InsertActivityParams{
			ID: pgID, OrganizationID: org, ApiaryID: pgtype.UUID{Bytes: apiaryID, Valid: true},
			PerformedBy: pgtype.UUID{Bytes: performedBy, Valid: true},
			JourneyID:   journeyIDParam(journeyID),
			Type:        *data.Type, OccurredAt: pgtype.Date{Time: occurredAt, Valid: true},
			Attributes: attrsJSON, UpdatedAt: incomingTS,
		}); err != nil {
			return OpResult{}, err
		}
		want := activityRowState{apiaryID: apiaryID.String(), typ: *data.Type, occurredAt: *data.OccurredAt, attributes: attrs}
		if err := writeActivityAuditLog(ctx, q, org, userID, op, history.ChangeCreate, activityRowState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Retried id: idempotent no-op on identical content (PowerSync's
	// forward-retry, sync.md §6.2), else a genuine conflict — logged, server
	// keeps its (first-write-wins) row, since #39 has no edit path yet for a
	// differing resend to legitimately supersede it.
	var existingAttrs map[string]any
	_ = json.Unmarshal(existing.Attributes, &existingAttrs)
	sameContent := uuidString(existing.ApiaryID) == apiaryID.String() &&
		existing.Type == *data.Type &&
		existing.OccurredAt.Time.Format(dateLayout) == *data.OccurredAt &&
		attributesEqual(existingAttrs, attrs)
	if sameContent {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	if err := logActivityConflict(ctx, q, org, userID, op, existing); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

func writeActivityAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, before, after activityRowState) error {
	var oldFields map[string]any
	if changeType != history.ChangeCreate {
		oldFields = before.fields()
	}
	changedFields, change, err := history.ComputeChange(changeType, oldFields, after.fields())
	if err != nil {
		return fmt.Errorf("compute activity change: %w", err)
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
		EntityType:     entityTypeActivity,
		EntityID:       pgtype.UUID{Bytes: id, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// logActivityConflict preserves a rejected retried-id resend (history.md §6
// "LWW losers are not lost") — mirrors apiaries/api/sync.go's logConflict.
func logActivityConflict(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, stored sqlcgen.ActivitiesActivity) error {
	winning, err := json.Marshal(map[string]any{
		"id":          uuidString(stored.ID),
		"apiary_id":   uuidString(stored.ApiaryID),
		"type":        stored.Type,
		"occurred_at": stored.OccurredAt.Time.Format(dateLayout),
		"updated_at":  stored.UpdatedAt.Time,
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
		EntityType:     entityTypeActivity,
		EntityID:       stored.ID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}
