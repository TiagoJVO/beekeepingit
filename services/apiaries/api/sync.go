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

type apiaryData struct {
	Name      *string `json:"name"`
	HiveCount *int32  `json:"hive_count"`
	Notes     *string `json:"notes"`
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

func validateOp(i int, op Op) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put, patch or delete"})
	}
	if op.EntityType != entityTypeApiary {
		errs = append(errs, problem.FieldError{Field: prefix + ".entity_type", Code: "invalid", Message: "entity_type must be apiary"})
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
	if op.Op == "patch" && data.Name == nil && data.HiveCount == nil && data.Notes == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "required", Message: "patch must change at least one field"})
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
			res, err := applyOp(r.Context(), q, org, userID, op)
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

// rowState is the mutable projection of an apiary the LWW logic reasons about.
type rowState struct {
	name      string
	hive      int32
	notes     string // "" means unset — an apiary's own free-text content, not personal data (§7.3)
	deletedAt pgtype.Timestamptz
}

func (a rowState) sameAs(b rowState) bool {
	return a.name == b.name && a.hive == b.hive && a.notes == b.notes && a.deletedAt.Valid == b.deletedAt.Valid
}

// fields projects a rowState to the plain field map history.ComputeChange
// diffs — only soft/scalar values, never denormalized personal data (§7.3).
// notes is the apiary's own content (FR-AP-8, #196), not personal data.
func (a rowState) fields() map[string]any {
	m := map[string]any{"name": a.name, "hive_count": a.hive}
	if a.notes != "" {
		m["notes"] = a.notes
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
			ID: pgID, OrganizationID: org, Name: want.name, HiveCount: want.hive,
			Notes:     notesParamFromState(want.notes),
			UpdatedAt: incomingTS, DeletedAt: want.deletedAt,
		}); err != nil {
			return OpResult{}, err
		}
		if err := writeAuditLog(ctx, q, org, userID, op, history.ChangeCreate, rowState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	current := rowState{name: stored.Name, hive: stored.HiveCount, notes: textOf(stored.Notes), deletedAt: stored.DeletedAt}
	want := mergeOp(current, op, data)

	// Strictly-newer incoming wins (§4.1).
	if op.UpdatedAt.After(stored.UpdatedAt.Time) {
		if err := q.UpdateApiary(ctx, sqlcgen.UpdateApiaryParams{
			OrganizationID: org, ID: pgID, Name: want.name, HiveCount: want.hive,
			Notes:     notesParamFromState(want.notes),
			UpdatedAt: incomingTS, DeletedAt: want.deletedAt,
		}); err != nil {
			return OpResult{}, err
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

// mergeOp computes the row an op would produce, given the current state (empty
// for a create). put replaces; patch overlays provided fields; delete sets the
// tombstone (§4.5).
func mergeOp(current rowState, op Op, data apiaryData) rowState {
	switch op.Op {
	case "put":
		out := rowState{}
		if data.Name != nil {
			out.name = *data.Name
		}
		if data.HiveCount != nil {
			out.hive = *data.HiveCount
		}
		if data.Notes != nil {
			out.notes = *data.Notes
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
	changedFields, change := history.ComputeChange(changeType, oldFields, newFields)

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
		"id":         uuidString(stored.ID),
		"name":       stored.Name,
		"hive_count": stored.HiveCount,
		"notes":      textPtr(stored.Notes),
		"updated_at": stored.UpdatedAt.Time,
		"deleted_at": timePtr(stored.DeletedAt),
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
