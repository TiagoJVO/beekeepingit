// Package api (this file) — the internal sync validate/apply endpoints (#50,
// FR-OF-1/Q-SYNC, sync.md §5.2/§6) the write-back coordinator
// (services/sync) calls so creating, editing, completing, reopening or
// deleting a todo offline (queued locally via PowerSync) reconciles on sync,
// exactly like activities' own sync.go. There is no bespoke "complete"/
// "reopen" wire op: PowerSync only ever queues put/patch/delete, so an
// offline complete/reopen flows as an ordinary patch that changes
// status/completed_at, applied by the SAME LWW path as any other edit (see
// mergeTodoOp's doc comment) — the audit row for it is an ordinary
// history.ChangeUpdate with changed_fields=['status','completed_at'].
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
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/todos/store/sqlc/gen"
)

// maxBatchOps/maxSyncBatchBodyBytes mirror activities/api/sync.go's
// identical caps (same rationale: applyTodoBatch holds this whole batch's
// writes in one local transaction).
const (
	maxBatchOps           = 500
	maxSyncBatchBodyBytes = 8 << 20 // 8 MiB
)

// Op is one CRUD op in a client sync batch — the todos-service subset of the
// wire shape services/sync/api/coordinator.go fans out (entity_type "todo").
// Mirrors activities/api/sync.go's Op.
type Op struct {
	Op         string          `json:"op"`          // put | patch | delete
	EntityType string          `json:"entity_type"` // todo
	ID         string          `json:"id"`
	Data       json.RawMessage `json:"data"`
	UpdatedAt  time.Time       `json:"updated_at"` // device time; LWW comparator
}

// Batch is one client transaction — the body of validate/apply.
type Batch struct {
	Ops []Op `json:"ops"`
}

// todoData is the sync wire shape for an entityTypeTodo op's `data`. Unlike
// activities' JSONB-attributes bag, every field here is a plain typed
// pointer — nil means "this op didn't touch this column at all" (mirrors
// apiaries' apiaryData.Notes "absent means don't touch" convention, sync.go's
// own doc comment there): the client's local TodosRepository issues TWO
// distinct SQL UPDATEs depending on the action —
//   - update() (a genuine edit): SETs title/description/due_date/priority/
//     assignee_id together (status/completed_at absent from that op's data).
//   - complete()/reopen(): SETs ONLY status/completed_at (every other field
//     absent from that op's data).
//
// A field that IS present but explicitly cleared (e.g. an edit that clears
// description/assignee_id) is carried as a non-nil pointer to the EMPTY
// string, not JSON null — matching common.go's textOf/dateOf/uuidOf ""
// sentinel convention throughout this service, so "absent" (leave untouched)
// and "present-but-empty" (explicitly cleared) are never conflated even
// though both would otherwise decode to a nil Go pointer for a bare
// `*string` carrying JSON `null`.
type todoData struct {
	Title       *string `json:"title"`
	Description *string `json:"description"`
	DueDate     *string `json:"due_date"`
	Priority    *string `json:"priority"`
	Status      *string `json:"status"`
	CompletedAt *string `json:"completed_at"`
	AssigneeID  *string `json:"assignee_id"`
}

// Per-op apply outcomes (sync.md §5.2), mirroring activities.
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
func InternalSyncRouter(pool *pgxpool.Pool, verifier *MemberVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/validate", validateTodoBatch(verifier))
	r.Post("/apply", applyTodoBatch(pool, verifier))
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

// resolveAssigneeOwnership verifies every DISTINCT, well-formed, non-empty
// assignee_id in the batch up front — de-duplicated (one upstream call per
// distinct assignee, not one per op — mirrors activities'
// resolveApiaryOwnership's own HIGH/MEDIUM review fix) and before any DB
// transaction is opened (never hold a pooled connection open across a
// blocking cross-service HTTP call). It returns a per-request
// `assignee_id string → belongs to callerOrgID?` map both the apply and
// validate paths then consult purely in-memory.
//
// Fail-closed: a transport/5xx error verifying ANY distinct id aborts the
// WHOLE batch (returned error → the caller writes a 500, the batch stays
// queued and heals on retry). A 404/cross-org id is NOT an error — it lands
// in the map as `false`. Ops whose assignee_id is missing, empty, or
// malformed are skipped here (structural validation rejects a malformed one
// independently, and there is nothing to look up for an empty/absent one).
func resolveAssigneeOwnership(ctx context.Context, verifier *MemberVerifier, bearer, callerOrgID string, batch Batch) (map[string]bool, error) {
	owned := map[string]bool{}
	for _, op := range batch.Ops {
		var data todoData
		if len(op.Data) > 0 {
			if err := json.Unmarshal(op.Data, &data); err != nil {
				continue // malformed data — structural validation handles it
			}
		}
		if data.AssigneeID == nil || *data.AssigneeID == "" {
			continue
		}
		assigneeID := *data.AssigneeID
		if _, err := uuid.Parse(assigneeID); err != nil {
			continue // malformed id — structural validation handles it
		}
		if _, done := owned[assigneeID]; done {
			continue // already resolved this distinct id — the de-dup
		}
		belongs, err := verifier.BelongsToOrg(ctx, bearer, callerOrgID, assigneeID)
		if err != nil {
			return nil, err // fail closed: whole batch aborts
		}
		owned[assigneeID] = belongs
	}
	return owned, nil
}

// validateTodoBatch dry-runs every op against the same rules applyTodoOp
// enforces, INCLUDING the cross-org assignee_id ownership check. The
// ownership HTTP calls are made ONCE per distinct assignee_id, up front
// (resolveAssigneeOwnership); the per-op check below is then a pure
// in-memory map lookup.
func validateTodoBatch(verifier *MemberVerifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, _, ok := requireOrg(w, r)
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
		owned, err := resolveAssigneeOwnership(r.Context(), verifier, bearer, uuidString(org), batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "validate todo batch: verify assignee membership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var fieldErrs []problem.FieldError
		for i, op := range batch.Ops {
			fieldErrs = append(fieldErrs, validateTodoOp(i, op, owned)...)
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more ops are invalid", fieldErrs...))
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]bool{"valid": true})
	}
}

// validateTodoOp validates one op's shape and, when well-formed, the
// cross-org assignee_id ownership guard — consulting the pre-resolved
// `owned` map (resolveAssigneeOwnership already made the single upstream
// call per distinct id) rather than making any HTTP call itself.
//
// put/patch/delete: a delete op carries no data at all (mirrors activities'
// validateActivityOp — the row is simply tombstoned by id). title/priority
// are REQUIRED on "put" (there is no existing row to fall back to for a
// create) but OPTIONAL on "patch" — a status-only complete/reopen patch
// (this file's package doc) carries neither.
func validateTodoOp(i int, op Op, owned map[string]bool) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put, patch or delete"})
	}
	if op.EntityType != entityTypeTodo {
		errs = append(errs, problem.FieldError{Field: prefix + ".entity_type", Code: "invalid", Message: "entity_type must be todo"})
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

	var data todoData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}

	switch {
	case op.Op == "put" && (data.Title == nil || strings.TrimSpace(*data.Title) == ""):
		errs = append(errs, problem.FieldError{Field: prefix + ".data.title", Code: "required", Message: "title is required"})
	case data.Title != nil && len(*data.Title) > maxTitleLength:
		errs = append(errs, problem.FieldError{Field: prefix + ".data.title", Code: "too_long", Message: fmt.Sprintf("title must be at most %d characters", maxTitleLength)})
	}
	if data.Description != nil && len(*data.Description) > maxDescriptionLength {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.description", Code: "too_long", Message: fmt.Sprintf("description must be at most %d characters", maxDescriptionLength)})
	}
	if data.DueDate != nil && *data.DueDate != "" {
		if _, err := time.Parse(dateLayout, *data.DueDate); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.due_date", Code: "invalid", Message: "due_date must be a YYYY-MM-DD date"})
		}
	}
	switch {
	case op.Op == "put" && data.Priority == nil:
		errs = append(errs, problem.FieldError{Field: prefix + ".data.priority", Code: "required", Message: "priority is required"})
	case data.Priority != nil && !IsKnownPriority(*data.Priority):
		errs = append(errs, problem.FieldError{Field: prefix + ".data.priority", Code: "invalid", Message: fmt.Sprintf("priority must be one of %v", KnownPriorities())})
	}
	if data.Status != nil && !IsKnownStatus(*data.Status) {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.status", Code: "invalid", Message: fmt.Sprintf("status must be one of %v", Statuses)})
	}
	if data.CompletedAt != nil && *data.CompletedAt != "" {
		if _, err := time.Parse(time.RFC3339Nano, *data.CompletedAt); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.completed_at", Code: "invalid", Message: "completed_at must be an RFC3339 timestamp"})
		}
	}

	assigneeID := ""
	if data.AssigneeID != nil && *data.AssigneeID != "" {
		if _, err := uuid.Parse(*data.AssigneeID); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.assignee_id", Code: "invalid", Message: "assignee_id must be a UUID"})
		} else {
			assigneeID = *data.AssigneeID
		}
	}

	// Ownership: a pure map lookup against the pre-resolved result — only
	// when assignee_id was actually present, non-empty and well-formed
	// (resolveAssigneeOwnership only resolves ids that appear in a batch
	// op's data at all, so a patch that doesn't carry one has nothing to
	// check here).
	if assigneeID != "" && !owned[assigneeID] {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.assignee_id", Code: "not_found", Message: "assignee_id does not refer to a member of this organization"})
	}

	return errs
}

// applyTodoBatch applies the batch in one local transaction (sync.md
// §5.2/§6.2 "apply" phase). The cross-org assignee_id ownership guard is
// resolved UP FRONT, OUTSIDE the transaction (resolveAssigneeOwnership — no
// blocking cross-service HTTP call ever runs while a pooled Postgres
// connection is held), de-duplicated to one upstream call per distinct
// assignee_id; applyTodoOp then consults that map in-memory.
func applyTodoBatch(pool *pgxpool.Pool, verifier *MemberVerifier) http.HandlerFunc {
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
		owned, err := resolveAssigneeOwnership(r.Context(), verifier, bearer, uuidString(org), batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply todo sync batch: verify assignee membership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var results []OpResult
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			results = make([]OpResult, 0, len(batch.Ops))
			for _, op := range batch.Ops {
				res, err := applyTodoOp(r.Context(), q, owned, org, userID, op)
				if err != nil {
					return err
				}
				results = append(results, res)
			}
			return nil
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply todo sync batch failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		writeJSON(w, r, http.StatusOK, ApplyResponse{Results: results})
	}
}

// applyTodoOp applies one put/patch/delete op: consults the pre-resolved
// `owned` ownership map (resolveAssigneeOwnership already made the single
// up-front upstream call per distinct assignee_id — NO HTTP call happens
// here, inside the transaction), then either inserts a brand-new row,
// applies an LWW-compared update/tombstone over an existing one, or logs a
// losing offline edit as a conflict. Mirrors activities' applyActivityOp.
func applyTodoOp(ctx context.Context, q *sqlcgen.Queries, owned map[string]bool, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	var data todoData
	if op.Op != "delete" && len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}

	// Tenancy guard (D-23, CRITICAL) — a pure in-memory lookup against the
	// up-front ownership resolution, only when this op's data actually
	// carries a non-empty assignee_id: an unknown/foreign assignee_id, when
	// one IS present, is a no-op (mirrors activities' applyActivityOp's
	// "missing row ⇒ nothing to do" convention, ADR-0002 scope-hiding),
	// never a distinguishable error.
	if data.AssigneeID != nil && *data.AssigneeID != "" && !owned[*data.AssigneeID] {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	existing, err := q.GetTodoForUpdate(ctx, sqlcgen.GetTodoForUpdateParams{OrganizationID: org, ID: pgID})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	if missing {
		if op.Op == "delete" {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // nothing to tombstone
		}
		// put or patch against a row the server has never seen. Materializing
		// a brand-new row needs at least title + priority — validateTodoOp
		// GUARANTEES both for "put"; a "patch" missing either (an edit racing
		// ahead of its own create, or a status-only complete/reopen patch for
		// an id the server never received) has nothing to attach a row to, so
		// it is a no-op — the same "missing row ⇒ nothing to do" convention
		// activities' applyActivityOp uses. Guard both here: apply is an
		// independent endpoint and must not assume /validate ran on this
		// exact body.
		if data.Title == nil || data.Priority == nil {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
		want := mergeTodoOp(todoRowState{status: StatusOpen}, op, data)

		dueDateParam, err := dateParam(want.dueDate)
		if err != nil {
			return OpResult{}, err
		}
		assigneeParam, err := uuidParam(want.assigneeID)
		if err != nil {
			return OpResult{}, err
		}

		if _, err := q.InsertTodo(ctx, sqlcgen.InsertTodoParams{
			ID: pgID, OrganizationID: org, Title: want.title,
			Description: textParam(want.description), DueDate: dueDateParam,
			Priority: want.priority, Status: want.status, AssigneeID: assigneeParam,
			UpdatedAt: incomingTS,
		}); err != nil {
			return OpResult{}, err
		}
		if err := writeTodoAuditLog(ctx, q, org, userID, op, history.ChangeCreate, todoRowState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	current := todoRowStateFromRow(existing)
	want := mergeTodoOp(current, op, data)

	// Strictly-newer incoming wins (sync.md §4.1).
	if op.UpdatedAt.After(existing.UpdatedAt.Time) {
		dueDateParam, err := dateParam(want.dueDate)
		if err != nil {
			return OpResult{}, err
		}
		assigneeParam, err := uuidParam(want.assigneeID)
		if err != nil {
			return OpResult{}, err
		}
		completedAtParam, err := timestampParam(want.completedAt)
		if err != nil {
			return OpResult{}, err
		}
		if err := q.UpdateTodoSync(ctx, sqlcgen.UpdateTodoSyncParams{
			OrganizationID: org, ID: pgID,
			Title: want.title, Description: textParam(want.description), DueDate: dueDateParam,
			Priority: want.priority, Status: want.status, CompletedAt: completedAtParam,
			AssigneeID: assigneeParam, UpdatedAt: incomingTS, DeletedAt: want.deletedAt,
		}); err != nil {
			return OpResult{}, err
		}
		changeType := history.ChangeUpdate
		if op.Op == "delete" {
			changeType = history.ChangeDelete
		}
		if err := writeTodoAuditLog(ctx, q, org, userID, op, changeType, current, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Equal or older. If it changes nothing, it is an idempotent re-send
	// (PowerSync's forward-retry, sync.md §6.2) — applied, no conflict.
	// Otherwise the server value is kept and the loser is logged (§4.1/§4.2).
	if want.sameAs(current) {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	if err := logTodoConflict(ctx, q, org, userID, op, existing); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

// mergeTodoOp computes the row an op would produce, given the current
// stored state (#50, mirrors activities' mergeActivityOp). delete sets the
// tombstone and otherwise leaves the row's content untouched. put and patch
// both overlay only the fields actually PRESENT in data (todoData's own doc
// comment: nil means "this op didn't touch this column") — a status-only
// complete/reopen patch therefore leaves title/description/due_date/
// priority/assignee_id exactly as they were, while a genuine edit patch
// (which always carries title/description/due_date/priority/assignee_id
// together, per the client repository's own single-UPDATE-statement
// convention) leaves status/completed_at untouched. put additionally
// UNDELETES (mirrors activities' own "put" convention — a fresh
// create/resend represents the row's live content); patch preserves
// whatever current.deletedAt already was.
func mergeTodoOp(current todoRowState, op Op, data todoData) todoRowState {
	if op.Op == "delete" {
		current.deletedAt = pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}
		return current
	}
	want := current
	if data.Title != nil {
		want.title = *data.Title
	}
	if data.Description != nil {
		want.description = *data.Description
	}
	if data.DueDate != nil {
		want.dueDate = *data.DueDate
	}
	if data.Priority != nil {
		want.priority = *data.Priority
	}
	if data.Status != nil {
		want.status = *data.Status
	}
	if data.CompletedAt != nil {
		want.completedAt = *data.CompletedAt
	}
	if data.AssigneeID != nil {
		want.assigneeID = *data.AssigneeID
	}
	if op.Op == "put" {
		want.deletedAt = pgtype.Timestamptz{}
	}
	return want
}

// writeTodoAuditLog appends one history.md §3 row for an applied
// create/update/delete (including a complete/reopen transition, applied as
// an ordinary update — this file's package doc), in the same local
// transaction as the domain write (§4). It must NOT be called for the no-op
// (idempotent replay) or LWW-loss branches of applyTodoOp — those apply no
// domain change, so they get no audit row (§4 "Idempotency"; §6 "LWW losers"
// go to sync_conflict_log instead, via logTodoConflict, not here). The
// REST-path counterpart is write.go's writeTodoAuditLogTx.
func writeTodoAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, before, after todoRowState) error {
	var oldFields map[string]any
	if changeType != history.ChangeCreate {
		oldFields = before.fields()
	}
	newFields := after.fields()
	if changeType == history.ChangeDelete {
		// A tombstone's "after" is nil, not the row's still-live field
		// values — mirrors write.go's writeTodoAuditLogTx.
		newFields = nil
	}
	changedFields, change, err := history.ComputeChange(changeType, oldFields, newFields)
	if err != nil {
		return fmt.Errorf("compute todo change: %w", err)
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
		EntityType:     entityTypeTodo,
		EntityID:       pgtype.UUID{Bytes: id, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// logTodoConflict preserves a rejected retried-id resend (history.md §6
// "LWW losers are not lost") — mirrors activities/api/sync.go's
// logActivityConflict.
func logTodoConflict(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, stored sqlcgen.TodosTodo) error {
	winning, err := json.Marshal(map[string]any{
		"id":           uuidString(stored.ID),
		"title":        stored.Title,
		"description":  textOf(stored.Description),
		"due_date":     dateOf(stored.DueDate),
		"priority":     stored.Priority,
		"status":       stored.Status,
		"completed_at": timestampOf(stored.CompletedAt),
		"assignee_id":  uuidOf(stored.AssigneeID),
		"updated_at":   stored.UpdatedAt.Time,
		"deleted_at":   timePtr(stored.DeletedAt),
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
		EntityType:     entityTypeTodo,
		EntityID:       stored.ID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}
