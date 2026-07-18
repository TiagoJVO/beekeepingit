// Package api (this file) — the internal sync validate/apply endpoints (#45,
// FR-OF-1/Q-SYNC, sync.md §5.2/§6) the write-back coordinator (services/sync)
// calls so creating, editing, closing or deleting a journey offline (queued
// locally via PowerSync) reconciles on sync, exactly like activities'/
// apiaries' own sync.go.
//
// This service owns TWO sync wire entity types (mirrors apiaries' own
// `apiary`/`apiary_counter` split, services/apiaries/api/sync.go): `journey`
// (the journey's own name/main_activity_type/status — full-resubmit on both
// put and patch, like activities' activityData) and `journey_plan_item` (one
// "this apiary is on the plan" fact per row, put/delete only — no patch,
// since a plan item has no mutable content of its own once created, mirroring
// apiary_counter's own put/patch-only restriction but the other way around:
// a plan item's identity, unlike a counter's, IS a stable client-generated
// id, so delete-by-id needs no enrichment). A single client transaction
// commonly carries BOTH kinds together (e.g. creating a journey offline
// queues its own row plus one `journey_plan_item` put per selected apiary) —
// services/sync/api/coordinator.go routes both to this service's
// INTERNAL_JOURNEYS_URL, and this file's applyJourneyBatch applies them
// together in ONE local transaction, in queued order, so a plan-item op
// referencing a journey_id inserted earlier in the SAME batch sees it.
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

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/journeys/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// maxBatchOps/maxSyncBatchBodyBytes mirror activities'/apiaries' identical
// caps (same rationale: applyBatch holds this whole batch's writes in one
// local transaction).
const (
	maxBatchOps           = 500
	maxSyncBatchBodyBytes = 8 << 20 // 8 MiB
)

// Op is one CRUD op in a client sync batch — mirrors activities'/apiaries'
// own Op.
type Op struct {
	Op         string          `json:"op"`          // put | patch | delete
	EntityType string          `json:"entity_type"` // journey | journey_plan_item
	ID         string          `json:"id"`
	Data       json.RawMessage `json:"data"`
	UpdatedAt  time.Time       `json:"updated_at"` // device time; LWW comparator
}

// Batch is one client transaction — the body of validate/apply.
type Batch struct {
	Ops []Op `json:"ops"`
}

// journeyData is the sync wire shape for an entityTypeJourney op's `data` —
// the same {name, main_activity_type[, status]} shape write.go's
// journeyCreateRequest/journeyUpdateRequest carry over REST, since both
// paths must accept identical content. name/main_activity_type are ALWAYS
// present on both put and patch (full-resubmit convention, this package's
// write.go doc comment); status is optional both times — absent on put
// defaults to StatusOpen (a materializing offline create), absent on patch
// preserves the row's current status (an edit that doesn't touch it — the
// common case, since the client's "close journey" action is the only UI
// affordance that ever sets it).
type journeyData struct {
	Name             *string `json:"name"`
	MainActivityType *string `json:"main_activity_type"`
	Status           *string `json:"status"`
}

// journeyPlanItemData is the sync wire shape for an entityTypeJourneyPlanItem
// `put` op's `data` — journey_id + apiary_id identify what this row means;
// both are always required (put is the only content-bearing op for this
// entity type — delete carries no data, since the item's own stable id is
// enough to remove it, migrations/00001_create_journeys.sql's doc comment).
type journeyPlanItemData struct {
	JourneyID *string `json:"journey_id"`
	ApiaryID  *string `json:"apiary_id"`
}

// Per-op apply outcomes (sync.md §5.2), mirroring activities/apiaries.
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
// Coordinator already expects for every owning service. Mount under
// "/internal/sync" behind the OIDC authn + org-resolver middleware.
func InternalSyncRouter(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/validate", validateJourneyBatch(verifier))
	r.Post("/apply", applyJourneyBatch(pool, verifier))
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

// resolveApiaryOwnership verifies every DISTINCT, well-formed apiary_id
// carried by a `journey_plan_item` PUT op in the batch, up front —
// de-duplicated to one upstream call per distinct id (verifyApiaryIDs) and
// before any DB transaction is opened, mirroring activities' own
// resolveApiaryOwnership (its doc comment's HIGH/MEDIUM review-fix
// rationale applies identically here).
func resolveApiaryOwnership(ctx context.Context, verifier *ApiaryVerifier, bearer string, batch Batch) (map[string]bool, error) {
	var ids []uuid.UUID
	seen := map[string]bool{}
	for _, op := range batch.Ops {
		if op.EntityType != entityTypeJourneyPlanItem || op.Op == "delete" {
			continue
		}
		var data journeyPlanItemData
		if len(op.Data) > 0 {
			if err := json.Unmarshal(op.Data, &data); err != nil {
				continue // malformed data — structural validation handles it
			}
		}
		if data.ApiaryID == nil {
			continue
		}
		id, err := uuid.Parse(*data.ApiaryID)
		if err != nil {
			continue // malformed id — structural validation handles it
		}
		if seen[id.String()] {
			continue
		}
		seen[id.String()] = true
		ids = append(ids, id)
	}
	return verifyApiaryIDs(ctx, verifier, bearer, ids)
}

func validateJourneyBatch(verifier *ApiaryVerifier) http.HandlerFunc {
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
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "validate journey batch: verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var fieldErrs []problem.FieldError
		for i, op := range batch.Ops {
			switch op.EntityType {
			case entityTypeJourneyPlanItem:
				fieldErrs = append(fieldErrs, validateJourneyPlanItemOp(i, op, owned)...)
			default:
				fieldErrs = append(fieldErrs, validateJourneyOp(i, op)...)
			}
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more ops are invalid", fieldErrs...))
			return
		}
		writeJSON(w, r, http.StatusOK, map[string]bool{"valid": true})
	}
}

func validateJourneyOp(i int, op Op) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put, patch or delete"})
	}
	if op.EntityType != entityTypeJourney {
		errs = append(errs, problem.FieldError{Field: prefix + ".entity_type", Code: "invalid", Message: "entity_type must be journey or journey_plan_item"})
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

	var data journeyData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}
	// name/main_activity_type are ALWAYS required, on both put and patch —
	// the full-resubmit convention this file's doc comment describes.
	if data.Name == nil || *data.Name == "" {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.name", Code: "required", Message: "name is required"})
	} else if len(*data.Name) > maxNameLength {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.name", Code: "too_long", Message: fmt.Sprintf("name must be at most %d characters", maxNameLength)})
	}
	if data.MainActivityType == nil || !IsKnownMainActivityType(*data.MainActivityType) {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.main_activity_type", Code: "invalid", Message: fmt.Sprintf("main_activity_type must be one of the known activity types: %v", KnownMainActivityTypes())})
	}
	if data.Status != nil && !IsKnownStatus(*data.Status) {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.status", Code: "invalid", Message: fmt.Sprintf("status must be one of %v", []string{StatusOpen, StatusClosed})})
	}
	return errs
}

// validateJourneyPlanItemOp validates one journey_plan_item op: put or
// delete only (no patch — a plan item has no mutable content of its own,
// this file's doc comment); put requires a well-formed journey_id and an
// apiary_id that the pre-resolved `owned` map (resolveApiaryOwnership already
// made the single upstream call per distinct id) confirms belongs to the
// caller's org.
func validateJourneyPlanItemOp(i int, op Op, owned map[string]bool) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put or delete for journey_plan_item (plan items have no patch)"})
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

	var data journeyPlanItemData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}
	if data.JourneyID == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.journey_id", Code: "required", Message: "journey_id is required"})
	} else if _, err := uuid.Parse(*data.JourneyID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.journey_id", Code: "invalid", Message: "journey_id must be a UUID"})
	}

	apiaryID := ""
	if data.ApiaryID == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "required", Message: "apiary_id is required"})
	} else if _, err := uuid.Parse(*data.ApiaryID); err != nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
	} else {
		apiaryID = *data.ApiaryID
	}
	if apiaryID != "" && !owned[apiaryID] {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary in this organization"})
	}
	return errs
}

// applyJourneyBatch applies the batch in one local transaction. The
// cross-org apiary_id ownership guard is resolved UP FRONT, OUTSIDE the
// transaction (resolveApiaryOwnership — mirrors activities' own HIGH review
// fix: no blocking cross-service HTTP call ever runs while a pooled Postgres
// connection is held).
func applyJourneyBatch(pool *pgxpool.Pool, verifier *ApiaryVerifier) http.HandlerFunc {
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
		owned, err := resolveApiaryOwnership(r.Context(), verifier, bearer, batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply journey sync batch: verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var results []OpResult
		err = withTx(r.Context(), pool, func(tx pgx.Tx, q *sqlcgen.Queries) error {
			results = make([]OpResult, 0, len(batch.Ops))
			for _, op := range batch.Ops {
				var (
					res OpResult
					err error
				)
				if op.EntityType == entityTypeJourneyPlanItem {
					res, err = applyJourneyPlanItemOp(r.Context(), tx, q, org, userID, owned, op)
				} else {
					res, err = applyJourneyOp(r.Context(), q, org, userID, op)
				}
				if err != nil {
					return err
				}
				results = append(results, res)
			}
			return nil
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply journey sync batch failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		writeJSON(w, r, http.StatusOK, ApplyResponse{Results: results})
	}
}

// applyJourneyOp applies one journey put/patch/delete op — mirrors
// activities' applyActivityOp, minus the apiary_id concern (a `journey` op
// never touches the plan; journey_plan_item ops handle that separately).
func applyJourneyOp(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	var data journeyData
	if op.Op != "delete" && len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}

	existing, err := q.GetJourneyForUpdate(ctx, sqlcgen.GetJourneyForUpdateParams{OrganizationID: org, ID: pgID})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	if missing {
		if op.Op == "delete" {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // nothing to tombstone
		}
		// put or patch against a row the server has never seen. Materializing
		// a brand-new row needs name + main_activity_type — validateJourneyOp
		// GUARANTEES both for put AND patch (full-resubmit convention), but
		// apply is an independent endpoint and must not assume /validate ran
		// on this exact body (mirrors activities' own MEDIUM #304 fix): a
		// nil here is a no-op, never a deref panic.
		if data.Name == nil || data.MainActivityType == nil {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
		status := StatusOpen
		if data.Status != nil {
			status = *data.Status
		}
		if _, err := q.InsertJourney(ctx, sqlcgen.InsertJourneyParams{
			ID: pgID, OrganizationID: org, Name: *data.Name, MainActivityType: *data.MainActivityType,
			Status: status, UpdatedAt: incomingTS,
		}); err != nil {
			return OpResult{}, err
		}
		want := journeyRowState{name: *data.Name, mainActivityType: *data.MainActivityType, status: status}
		if err := writeJourneyAuditLog(ctx, q, org, userID, op, history.ChangeCreate, journeyRowState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	currentApiaryIDsList, err := currentApiaryIDs(ctx, q, org, pgID)
	if err != nil {
		return OpResult{}, err
	}
	current := journeyRowState{
		name: existing.Name, mainActivityType: existing.MainActivityType, status: existing.Status,
		apiaryIDs: sortedStrings(currentApiaryIDsList), deletedAt: existing.DeletedAt,
	}
	want := mergeJourneyOp(current, op, data)

	// Strictly-newer incoming wins (sync.md §4.1).
	if op.UpdatedAt.After(existing.UpdatedAt.Time) {
		if err := q.UpdateJourneySync(ctx, sqlcgen.UpdateJourneySyncParams{
			OrganizationID: org, ID: pgID, Name: want.name, MainActivityType: want.mainActivityType,
			Status: want.status, UpdatedAt: incomingTS, DeletedAt: want.deletedAt,
		}); err != nil {
			return OpResult{}, err
		}
		changeType := history.ChangeUpdate
		if op.Op == "delete" {
			changeType = history.ChangeDelete
		}
		if err := writeJourneyAuditLog(ctx, q, org, userID, op, changeType, current, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Equal or older. If it changes nothing, it is an idempotent re-send —
	// applied, no conflict. Otherwise the server value is kept and the loser
	// is logged (sync.md §4.1/§4.2).
	if want.sameAs(current) {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	if err := logJourneyConflict(ctx, q, org, userID, op, existing); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

// mergeJourneyOp computes the row a `journey` op would produce, given the
// current stored state — mirrors activities' mergeActivityOp. delete sets
// the tombstone; put/patch are both a full resubmit of name/
// main_activity_type (validateJourneyOp's doc comment) with status falling
// back to current.status when absent (an edit that doesn't touch it — the
// common case). apiary_ids is NEVER touched by a `journey` op — always
// carried over from current unchanged (journey_plan_item ops own that).
func mergeJourneyOp(current journeyRowState, op Op, data journeyData) journeyRowState {
	if op.Op == "delete" {
		current.deletedAt = pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}
		return current
	}
	want := journeyRowState{
		name: current.name, mainActivityType: current.mainActivityType, status: current.status,
		apiaryIDs: current.apiaryIDs, deletedAt: current.deletedAt,
	}
	if data.Name != nil {
		want.name = *data.Name
	}
	if data.MainActivityType != nil {
		want.mainActivityType = *data.MainActivityType
	}
	if data.Status != nil {
		want.status = *data.Status
	}
	if op.Op == "put" {
		// A full replace implicitly UNDELETES — mirrors activities'/apiaries'
		// own "put" convention (a fresh create/resend represents the row's
		// live content).
		want.deletedAt = pgtype.Timestamptz{}
	}
	return want
}

// applyJourneyPlanItemOp applies one journey_plan_item put/delete op — a
// pure set-membership primitive (mirrors apiary_counter's simplicity: no LWW
// timestamp compare, since there is no "content" to compare, only presence/
// absence). Every add/remove that actually changes the journey's live plan
// is folded into a `journey`-entity "update" audit row (changed_fields
// includes "apiary_ids") via writeJourneyPlanAuditLog, so a journey's
// combined timeline stays coherent regardless of whether a change arrived
// as a REST PATCH (write.go) or an independent sync op here.
//
// Takes the raw enclosing pgx.Tx (in addition to q, which wraps it) purely
// for the put path's SAVEPOINT around InsertJourneyPlanItem — see that
// call's own comment for why.
func applyJourneyPlanItemOp(ctx context.Context, tx pgx.Tx, q *sqlcgen.Queries, org pgtype.UUID, userID string, owned map[string]bool, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}

	if op.Op == "delete" {
		item, err := q.GetJourneyPlanItem(ctx, sqlcgen.GetJourneyPlanItemParams{OrganizationID: org, ID: pgID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // nothing to remove
			}
			return OpResult{}, err
		}
		if item.DeletedAt.Valid {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // already gone: idempotent
		}
		before, err := currentApiaryIDs(ctx, q, org, item.JourneyID)
		if err != nil {
			return OpResult{}, err
		}
		if _, err := q.SoftDeleteJourneyPlanItem(ctx, sqlcgen.SoftDeleteJourneyPlanItemParams{
			OrganizationID: org, ID: pgID, DeletedAt: pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		}); err != nil {
			return OpResult{}, err
		}
		after, err := currentApiaryIDs(ctx, q, org, item.JourneyID)
		if err != nil {
			return OpResult{}, err
		}
		if err := writeJourneyPlanAuditLog(ctx, q, org, userID, item.JourneyID, op.UpdatedAt, before, after); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// put: validateJourneyPlanItemOp guarantees journey_id/apiary_id are
	// present and well-formed by the time validate has run, but apply is an
	// independent endpoint (sync.md §6.2) — guard nils defensively rather
	// than assume it.
	var data journeyPlanItemData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}
	if data.JourneyID == nil || data.ApiaryID == nil {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	journeyID, err := uuid.Parse(*data.JourneyID)
	if err != nil {
		return OpResult{}, err
	}
	apiaryID, err := uuid.Parse(*data.ApiaryID)
	if err != nil {
		return OpResult{}, err
	}

	// Tenancy guard 1/2 (CRITICAL): apiary_id must be pre-confirmed as
	// belonging to the caller's org (resolveApiaryOwnership's up-front,
	// de-duplicated check) — an unknown/foreign apiary_id is a no-op, never
	// a distinguishable error (mirrors activities' own convention).
	if !owned[apiaryID.String()] {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	pgJourneyID := pgtype.UUID{Bytes: journeyID, Valid: true}
	// Tenancy guard 2/2: journey_id must belong to the caller's org and be
	// live — a plain org-scoped DB read (journeys owns this table directly,
	// unlike apiary_id which needs the cross-service HTTP check above). An
	// unknown/foreign/deleted journey_id is a no-op.
	journey, err := q.GetJourneyForUpdate(ctx, sqlcgen.GetJourneyForUpdateParams{OrganizationID: org, ID: pgJourneyID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
		return OpResult{}, err
	}
	if journey.DeletedAt.Valid {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	before, err := currentApiaryIDs(ctx, q, org, pgJourneyID)
	if err != nil {
		return OpResult{}, err
	}
	pgApiaryID := pgtype.UUID{Bytes: apiaryID, Valid: true}

	// This insert may hit either of journey_plan_items' two unique
	// constraints (constraintName's doc comment: the PK on `id`, or the
	// partial `(journey_id, apiary_id)` index) as an EXPECTED, benign race
	// rather than a real error — but Postgres aborts the WHOLE enclosing
	// transaction on any statement error, and this op runs inside
	// applyJourneyBatch's single per-request transaction alongside every
	// other op in the batch. Swallowing the error here and simply carrying
	// on (as this function used to) left that transaction poisoned: every
	// later statement — including the final commit — would fail with
	// "current transaction is aborted", turning a benign no-op into a 500
	// (caught by TestJourneysSync_Apply_DedupesApiaryOwnershipCalls and
	// TestJourneysSync_Apply_PlanItemAlreadyOnPlanViaDifferentIdIsNoOp).
	// Running the insert in its own SAVEPOINT (a pgx nested transaction) and
	// rolling back to it on a caught, expected violation contains the damage
	// to just this one statement, exactly like apiaries'/activities' own
	// upsert-based equivalents avoid it via ON CONFLICT — plan items can't
	// use a single ON CONFLICT clause here since either of TWO different
	// constraints may legitimately fire, and each needs different handling.
	spTx, err := tx.Begin(ctx)
	if err != nil {
		return OpResult{}, fmt.Errorf("begin plan item savepoint: %w", err)
	}
	_, insertErr := sqlcgen.New(spTx).InsertJourneyPlanItem(ctx, sqlcgen.InsertJourneyPlanItemParams{
		ID: pgID, OrganizationID: org, JourneyID: pgJourneyID, ApiaryID: pgApiaryID,
	})
	if insertErr != nil {
		if rbErr := spTx.Rollback(ctx); rbErr != nil {
			return OpResult{}, fmt.Errorf("rollback plan item savepoint: %w", rbErr)
		}
		if !isUniqueViolation(insertErr) {
			return OpResult{}, insertErr
		}
		switch constraintName(insertErr) {
		case "uq_journey_plan_items_journey_apiary_live":
			// This apiary is already on the journey's plan via a DIFFERENT
			// row id (e.g. two devices added it offline) — the desired STATE
			// already holds; benign no-op, no audit (nothing actually changed).
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		default:
			// PK collision on the op's own id: idempotent replay if this exact
			// row already exists with the same content, otherwise treated as a
			// harmless no-op too — a plan item has no mutable content to
			// meaningfully "conflict" over (this file's doc comment). The
			// savepoint rollback above already restored the outer transaction
			// (and so q, which wraps it) to a clean, usable state.
			existing, getErr := q.GetJourneyPlanItem(ctx, sqlcgen.GetJourneyPlanItemParams{OrganizationID: org, ID: pgID})
			if getErr == nil && existing.JourneyID == pgJourneyID && existing.ApiaryID == pgApiaryID {
				return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
			}
			logging.FromContext(ctx).WarnContext(ctx, "journey_plan_item id collision with different content; treating as no-op", slog.String("id", op.ID))
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
	}
	if err := spTx.Commit(ctx); err != nil {
		return OpResult{}, fmt.Errorf("commit plan item savepoint: %w", err)
	}

	after, err := currentApiaryIDs(ctx, q, org, pgJourneyID)
	if err != nil {
		return OpResult{}, err
	}
	if err := writeJourneyPlanAuditLog(ctx, q, org, userID, pgJourneyID, op.UpdatedAt, before, after); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
}

func writeJourneyAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, before, after journeyRowState) error {
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
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return err
	}
	auditID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             auditID,
		OrganizationID: org,
		EntityType:     entityTypeJourney,
		EntityID:       pgtype.UUID{Bytes: id, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// writeJourneyPlanAuditLog folds a journey_plan_item add/remove into a
// `journey`-entity "update" audit row keyed by journeyID, changed_fields
// ["apiary_ids"] — mirrors apiaries' writeCounterAuditLog's "entity_id is
// the PARENT's id, not this row's own" convention (a counter change is
// likewise logged under the apiary's own id, not a counter-specific id), so
// a journey's combined history timeline reads as one coherent story
// regardless of whether the change arrived via write.go's REST PATCH or an
// independent journey_plan_item sync op here. No-ops (writes nothing) when
// before/after are identical — the caller only invokes this when a real
// change occurred, but this stays defensive rather than relying on that.
func writeJourneyPlanAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, journeyID pgtype.UUID, occurredAt time.Time, before, after []string) error {
	beforeSorted, afterSorted := sortedStrings(before), sortedStrings(after)
	changedFields, change, err := history.ComputeChange(history.ChangeUpdate,
		map[string]any{"apiary_ids": beforeSorted}, map[string]any{"apiary_ids": afterSorted})
	if err != nil {
		return fmt.Errorf("compute journey plan change: %w", err)
	}
	if len(changedFields) == 0 {
		return nil // nothing actually changed — never write a no-op audit row
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
		EntityID:       journeyID,
		ChangeType:     history.ChangeUpdate,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: occurredAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// logJourneyConflict preserves a rejected retried-id resend (history.md §6
// "LWW losers are not lost") — mirrors activities'/apiaries' logConflict.
func logJourneyConflict(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, stored sqlcgen.JourneysJourney) error {
	winning, err := json.Marshal(map[string]any{
		"id":                 uuidString(stored.ID),
		"name":               stored.Name,
		"main_activity_type": stored.MainActivityType,
		"status":             stored.Status,
		"updated_at":         stored.UpdatedAt.Time,
		"deleted_at":         timePtr(stored.DeletedAt),
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
		EntityType:     entityTypeJourney,
		EntityID:       stored.ID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}

func timePtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}
