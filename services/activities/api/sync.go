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

// resolveApiaryOwnership verifies every DISTINCT, well-formed apiary_id in
// the batch up front — **de-duplicated** (HIGH/MEDIUM review fix: N ops
// against the same apiary cost exactly ONE upstream call, not N) and
// **before any DB transaction is opened** (HIGH review fix: never hold a
// pooled Postgres connection open across a blocking cross-service HTTP call —
// a 500-op batch × a 5s upstream timeout could otherwise pin one pooled
// connection for minutes and let a single authenticated caller exhaust the
// pool). It returns a per-request `apiary_id string → belongs?` map both the
// apply and validate paths then consult purely in-memory.
//
// Fail-closed (unchanged semantics): a transport/5xx error verifying ANY
// distinct id aborts the WHOLE batch (returned error → the caller writes a
// 500/relayed 502, the batch stays queued and heals on retry). A 404 /
// cross-org id is NOT an error — it lands in the map as `false`, so the
// per-op check rejects (validate) or no-ops (apply) exactly as before. Ops
// whose apiary_id is missing or malformed are skipped here (structural
// validation rejects them independently, and there is nothing to look up).
func resolveApiaryOwnership(ctx context.Context, verifier *ApiaryVerifier, bearer string, batch Batch) (map[string]bool, error) {
	owned := map[string]bool{}
	for _, op := range batch.Ops {
		var data activityData
		if len(op.Data) > 0 {
			if err := json.Unmarshal(op.Data, &data); err != nil {
				continue // malformed data — structural validation handles it
			}
		}
		if data.ApiaryID == nil {
			continue
		}
		apiaryID := *data.ApiaryID
		if _, err := uuid.Parse(apiaryID); err != nil {
			continue // malformed id — structural validation handles it
		}
		if _, done := owned[apiaryID]; done {
			continue // already resolved this distinct id — the de-dup
		}
		belongs, err := verifier.BelongsToOrg(ctx, bearer, apiaryID)
		if err != nil {
			return nil, err // fail closed: whole batch aborts
		}
		owned[apiaryID] = belongs
	}
	return owned, nil
}

// validateActivityBatch dry-runs every op against the same rules
// applyActivityOp enforces, INCLUDING the cross-org apiary_id ownership
// check. The ownership HTTP calls are made ONCE per distinct apiary_id, up
// front (resolveApiaryOwnership); the per-op check below is then a pure
// in-memory map lookup, so validate is both cheap and symmetric with apply.
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
		owned, err := resolveApiaryOwnership(r.Context(), verifier, bearer, batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "validate activity batch: verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var fieldErrs []problem.FieldError
		for i, op := range batch.Ops {
			fieldErrs = append(fieldErrs, validateActivityOp(i, op, owned)...)
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more ops are invalid", fieldErrs...))
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]bool{"valid": true})
	}
}

// validateActivityOp validates one op's shape/attribute-schema and, when
// well-formed, the cross-org apiary_id ownership guard — consulting the
// pre-resolved `owned` map (resolveApiaryOwnership already made the single
// upstream call per distinct id) rather than making any HTTP call itself.
func validateActivityOp(i int, op Op, owned map[string]bool) []problem.FieldError {
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
			return errs
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

	// Ownership: a pure map lookup against the pre-resolved result — only when
	// the apiary_id was well-formed (a malformed/missing id has nothing to
	// verify and is already reported above; resolveApiaryOwnership resolves
	// every well-formed distinct id, so the key is always present here).
	if apiaryID != "" && !owned[apiaryID] {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary in this organization"})
	}

	return errs
}

// applyActivityBatch applies the batch in one local transaction (sync.md
// §5.2/§6.2 "apply" phase). The cross-org apiary_id ownership guard is
// resolved UP FRONT, OUTSIDE the transaction (resolveApiaryOwnership — HIGH
// review fix: no blocking cross-service HTTP call ever runs while a pooled
// Postgres connection is held), de-duplicated to one upstream call per
// distinct apiary_id; applyActivityOp then consults that map in-memory.
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

		// Resolve ownership for every distinct apiary_id BEFORE opening the
		// transaction (zero-trust re-check — apply is a separate request from
		// validate, sync.md §6.2 — but done once, up front, not per-op inside
		// the tx). Fail closed on an upstream error: the whole batch aborts
		// and heals on PowerSync's idempotent forward-retry.
		bearer := r.Header.Get("Authorization")
		owned, err := resolveApiaryOwnership(r.Context(), verifier, bearer, batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply activity sync batch: verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var results []OpResult
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			results = make([]OpResult, 0, len(batch.Ops))
			for _, op := range batch.Ops {
				res, err := applyActivityOp(r.Context(), q, owned, org, userID, op)
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

// applyActivityOp applies one create-only op (#39 scope): consults the
// pre-resolved `owned` ownership map (resolveApiaryOwnership already made the
// single up-front upstream call per distinct apiary_id — NO HTTP call happens
// here, inside the transaction), then either inserts a brand-new row or, for
// a retried id, compares content for an idempotent no-op vs a content
// conflict (logged, server wins — there is no edit path yet for a genuinely
// different resend to legitimately win via LWW).
func applyActivityOp(ctx context.Context, q *sqlcgen.Queries, owned map[string]bool, org pgtype.UUID, userID string, op Op) (OpResult, error) {
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

	// Tenancy guard (FR-TEN-2, CRITICAL) — a pure in-memory lookup against the
	// up-front ownership resolution; an unknown/foreign apiary_id is a no-op
	// (mirrors applyCounterOp's own "missing row ⇒ nothing to do" convention,
	// ADR-0002 scope-hiding), never a distinguishable error.
	if !owned[apiaryID.String()] {
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
