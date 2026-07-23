// Package api (this file) — the internal sync validate/apply endpoints
// (#39/#40/#41, FR-OF-1/Q-SYNC, sync.md §5.2/§6) the write-back coordinator
// (services/sync) calls so creating, editing, or deleting an activity
// offline (queued locally via PowerSync) reconciles on sync, exactly like
// apiaries' own sync.go. #39 shipped create-only (put); #40/#41 extend
// validateActivityOp/applyActivityOp to also accept patch (edit) and
// delete (tombstone), the same way apiaries' sync.go grew from create-only
// to full CRUD, following #38's scope-split precedent (main.go's doc
// comment).
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
	Op         string          `json:"op"`          // put | patch | delete (#40/#41)
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
// journeyVerifier (#46) closes the same IDOR gap on the offline queue that
// write.go's createActivity closes on the REST path — journey_id must be
// ownership-checked here too, since the field PWA creates the vast majority
// of activities through THIS path, not REST.
func InternalSyncRouter(pool *pgxpool.Pool, verifier *ApiaryVerifier, journeyVerifier *JourneyVerifier) http.Handler {
	r := chi.NewRouter()
	r.Post("/validate", validateActivityBatch(verifier, journeyVerifier))
	r.Post("/apply", applyActivityBatch(pool, verifier, journeyVerifier))
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

// journeyIDKeyPresent reports whether raw's top-level JSON object actually
// carries a `"journey_id"` key at all — regardless of its value, INCLUDING
// an explicit `null` (#387's tri-state wire semantics). This is the ONLY way
// to distinguish "the client didn't touch this column" (key absent —
// PowerSync's patch opData carries only changed columns) from "the client
// explicitly cleared it" (key present, value `null`): both unmarshal
// activityData.JourneyID (a `*string`) to the SAME nil pointer, so that
// field alone can never tell the two apart. Same tri-state concept
// journeys' #385 default_attributes handles, though that field's
// json.RawMessage type lets a plain length check do the job — journey_id's
// `*string` wire type needs this explicit map-based presence check instead.
func journeyIDKeyPresent(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return false
	}
	_, present := m["journey_id"]
	return present
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
		parsed, err := uuid.Parse(*data.ApiaryID)
		if err != nil {
			continue // malformed id — structural validation handles it
		}
		// Keyed by the canonical form (not the raw client string) so a
		// non-canonically-cased but valid UUID still matches the lookups in
		// validateActivityOp/applyActivityOp, which both normalize via
		// uuid.Parse(...).String() — a mismatched key here silently no-ops
		// an op that WAS actually verified as owned.
		apiaryID := parsed.String()
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

// resolveJourneyOwnership is resolveApiaryOwnership's #46 counterpart:
// verifies every DISTINCT, well-formed journey_id in the batch up front —
// de-duplicated to one upstream call per distinct id, and before any DB
// transaction is opened (same HIGH-severity discipline resolveApiaryOwnership
// documents: never hold a pooled Postgres connection open across a blocking
// cross-service HTTP call). Ops whose journey_id is absent or malformed are
// skipped (structural validation handles those independently) — journey_id
// is optional, so most ops resolve nothing here at all.
func resolveJourneyOwnership(ctx context.Context, verifier *JourneyVerifier, bearer string, batch Batch) (map[string]bool, error) {
	owned := map[string]bool{}
	for _, op := range batch.Ops {
		var data activityData
		if len(op.Data) > 0 {
			if err := json.Unmarshal(op.Data, &data); err != nil {
				continue // malformed data — structural validation handles it
			}
		}
		if data.JourneyID == nil {
			continue
		}
		parsed, err := uuid.Parse(*data.JourneyID)
		if err != nil {
			continue // malformed id — structural validation handles it
		}
		// Canonical form, same rationale as resolveApiaryOwnership above.
		journeyID := parsed.String()
		if _, done := owned[journeyID]; done {
			continue // already resolved this distinct id — the de-dup
		}
		belongs, err := verifier.BelongsToOrg(ctx, bearer, journeyID)
		if err != nil {
			return nil, err // fail closed: whole batch aborts
		}
		owned[journeyID] = belongs
	}
	return owned, nil
}

// validateActivityBatch dry-runs every op against the same rules
// applyActivityOp enforces, INCLUDING the cross-org apiary_id ownership
// check. The ownership HTTP calls are made ONCE per distinct apiary_id, up
// front (resolveApiaryOwnership); the per-op check below is then a pure
// in-memory map lookup, so validate is both cheap and symmetric with apply.
func validateActivityBatch(verifier *ApiaryVerifier, journeyVerifier *JourneyVerifier) http.HandlerFunc {
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
		ownedJourneys, err := resolveJourneyOwnership(r.Context(), journeyVerifier, bearer, batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "validate activity batch: verify journey ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var fieldErrs []problem.FieldError
		for i, op := range batch.Ops {
			fieldErrs = append(fieldErrs, validateActivityOp(i, op, owned, ownedJourneys)...)
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
//
// put/patch/delete (#40/#41): a delete op carries no data at all (mirrors
// apiaries' validateApiaryOp — the row is simply tombstoned by id). put and
// patch are otherwise validated IDENTICALLY here: unlike apiaries' true
// partial-PATCH semantics, activities' edit UI always resubmits the
// COMPLETE current state (add_activity_screen.dart's doc comment) — the
// client's local ActivitiesRepository.update() always sets type/
// occurred_at/attributes together in one SQL UPDATE, so PowerSync's queued
// patch opData always carries all three, same as a put. The one real
// difference is apiary_id: REQUIRED on put (there is no existing row to
// fall back to for a create), OPTIONAL on patch (an edit that doesn't touch
// it — the common case, since the UI never exposes moving an activity to a
// different apiary — simply keeps the stored value; applyActivityOp's
// mergeActivityOp handles the fallback).
func validateActivityOp(i int, op Op, owned, ownedJourneys map[string]bool) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put, patch or delete"})
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

	if op.Op == "delete" {
		return errs
	}

	var data activityData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}

	apiaryID := ""
	switch data.ApiaryID {
	case nil:
		if op.Op == "put" {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "required", Message: "apiary_id is required"})
		}
	default:
		if parsed, err := uuid.Parse(*data.ApiaryID); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "invalid", Message: "apiary_id must be a UUID"})
		} else {
			apiaryID = parsed.String() // canonical form — matches owned's key
		}
	}

	// occurred_at is required on put; a patch may omit it — PowerSync
	// uploads only the columns that actually changed, and a save that
	// doesn't change the date (or changes only some other field) legitimately
	// produces a patch without occurred_at (#378). When present on either op
	// kind it must still be well-formed.
	if data.OccurredAt == nil || *data.OccurredAt == "" {
		if op.Op == "put" {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.occurred_at", Code: "required", Message: "occurred_at is required"})
		}
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
	// type is required on put; a patch may omit it for the same reason
	// occurred_at may (#378) — PowerSync's column diff. Attribute-bag
	// validation only runs when a type is actually present to validate
	// against (unchanged from before).
	if data.Type == nil || *data.Type == "" {
		if op.Op == "put" {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.type", Code: "required", Message: "type is required"})
		}
	} else if attrsOK {
		for _, e := range ValidateActivity(*data.Type, attrs) {
			errs = append(errs, problem.FieldError{Field: prefix + ".data." + e.Field, Code: e.Code, Message: e.Message})
		}
	}
	journeyID := ""
	if data.JourneyID != nil {
		if parsed, err := uuid.Parse(*data.JourneyID); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.journey_id", Code: "invalid", Message: "journey_id must be a UUID"})
		} else {
			journeyID = parsed.String() // canonical form — matches ownedJourneys's key
		}
	}

	// Ownership: a pure map lookup against the pre-resolved result — only when
	// the apiary_id was actually present and well-formed (resolveApiaryOwnership
	// only resolves apiary_ids that appear in a batch op's data at all, so a
	// patch that doesn't carry one has nothing to check here — the existing
	// row's own organization_id, already enforced elsewhere, is what matters
	// for an edit that doesn't move the activity).
	if apiaryID != "" && !owned[apiaryID] {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.apiary_id", Code: "not_found", Message: "apiary_id does not refer to an apiary in this organization"})
	}
	// Same ownership guard for journey_id (#46 — closes the IDOR gap where
	// this field was previously accepted with no verification at all).
	if journeyID != "" && !ownedJourneys[journeyID] {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.journey_id", Code: "not_found", Message: "journey_id does not refer to a journey in this organization"})
	}

	return errs
}

// applyActivityBatch applies the batch in one local transaction (sync.md
// §5.2/§6.2 "apply" phase). The cross-org apiary_id ownership guard is
// resolved UP FRONT, OUTSIDE the transaction (resolveApiaryOwnership — HIGH
// review fix: no blocking cross-service HTTP call ever runs while a pooled
// Postgres connection is held), de-duplicated to one upstream call per
// distinct apiary_id; applyActivityOp then consults that map in-memory.
func applyActivityBatch(pool *pgxpool.Pool, verifier *ApiaryVerifier, journeyVerifier *JourneyVerifier) http.HandlerFunc {
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

		// Resolve ownership for every distinct apiary_id AND journey_id
		// BEFORE opening the transaction (zero-trust re-check — apply is a
		// separate request from validate, sync.md §6.2 — but done once, up
		// front, not per-op inside the tx). Fail closed on an upstream
		// error: the whole batch aborts and heals on PowerSync's idempotent
		// forward-retry.
		bearer := r.Header.Get("Authorization")
		owned, err := resolveApiaryOwnership(r.Context(), verifier, bearer, batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply activity sync batch: verify apiary ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		ownedJourneys, err := resolveJourneyOwnership(r.Context(), journeyVerifier, bearer, batch)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "apply activity sync batch: verify journey ownership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		var results []OpResult
		err = withTx(r.Context(), pool, func(q *sqlcgen.Queries) error {
			results = make([]OpResult, 0, len(batch.Ops))
			for _, op := range batch.Ops {
				res, err := applyActivityOp(r.Context(), q, owned, ownedJourneys, org, userID, op)
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

// applyActivityOp applies one put/patch/delete op (#39/#40/#41): consults
// the pre-resolved `owned` ownership map (resolveApiaryOwnership already
// made the single up-front upstream call per distinct apiary_id — NO HTTP
// call happens here, inside the transaction), then either inserts a
// brand-new row, applies an LWW-compared update/tombstone over an existing
// one, or logs a losing offline edit as a conflict.
//
// GetActivityForUpdate (not GetActivity) is used here deliberately — it
// carries NO `deleted_at IS NULL` filter, unlike the old create-only code's
// GetActivity lookup. That distinction matters now that deletes exist: a
// tombstoned row must be treated as EXISTING (so a re-arriving op runs the
// LWW-compared UPDATE path below, potentially "undeleting" it on a
// strictly-newer put), never as "missing" — treating it as missing would
// attempt a fresh INSERT against a live primary key and fail outright.
func applyActivityOp(ctx context.Context, q *sqlcgen.Queries, owned, ownedJourneys map[string]bool, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	var data activityData
	if op.Op != "delete" && len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}

	// Tenancy guard (FR-TEN-2, CRITICAL) — a pure in-memory lookup against the
	// up-front ownership resolution, only when this op's data actually
	// carries an apiary_id: resolveApiaryOwnership only resolves ids that
	// appear in a batch op's data at all (its own doc comment), so a patch
	// that doesn't touch apiary_id (the common edit case) has nothing to
	// check here — an unknown/foreign apiary_id, when one IS present, is a
	// no-op (mirrors applyCounterOp's own "missing row ⇒ nothing to do"
	// convention, ADR-0002 scope-hiding), never a distinguishable error.
	if data.ApiaryID != nil {
		apiaryID, err := uuid.Parse(*data.ApiaryID)
		if err != nil {
			return OpResult{}, err
		}
		if !owned[apiaryID.String()] {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
	}
	// Same tenancy guard for journey_id (#46, CRITICAL — closes the IDOR gap
	// where this field was previously applied with no verification at all):
	// an unknown/foreign journey_id, when one IS present, no-ops the WHOLE
	// op — mirrors the apiary_id convention immediately above rather than
	// silently dropping just the journey_id and still writing the rest of
	// the activity, so the same "reject the write outright on a bad
	// cross-service reference" shape applies uniformly to both fields.
	if data.JourneyID != nil {
		journeyID, err := uuid.Parse(*data.JourneyID)
		if err != nil {
			return OpResult{}, err
		}
		if !ownedJourneys[journeyID.String()] {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
	}

	existing, err := q.GetActivityForUpdate(ctx, sqlcgen.GetActivityForUpdateParams{OrganizationID: org, ID: pgID})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	if missing {
		if op.Op == "delete" {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil // nothing to tombstone
		}
		// put or patch against a row the server has never seen. Materializing
		// a brand-new row needs the full create-shape — apiary_id + occurred_at
		// + type. validateActivityOp GUARANTEES all three for "put"; a "patch"
		// missing any of them (an edit racing ahead of its own create, or a
		// stray/partial edit for an id the server never received) has nothing
		// to attach a row to, so it is a no-op — the same "missing row ⇒
		// nothing to do" convention apiaries' applyOp uses. Guard ALL three
		// here: apply is an independent endpoint and must not assume /validate
		// ran on this exact body, so the *OccurredAt / *Type derefs below must
		// never fire on a nil (which would panic — MEDIUM #304 security review).
		if data.ApiaryID == nil || data.OccurredAt == nil || data.Type == nil {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
		apiaryID, err := uuid.Parse(*data.ApiaryID)
		if err != nil {
			return OpResult{}, err
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

		if _, err := q.InsertActivity(ctx, sqlcgen.InsertActivityParams{
			ID: pgID, OrganizationID: org, ApiaryID: pgtype.UUID{Bytes: apiaryID, Valid: true},
			PerformedBy: pgtype.UUID{Bytes: performedBy, Valid: true},
			JourneyID:   journeyIDParam(journeyID),
			Type:        *data.Type, OccurredAt: pgtype.Date{Time: occurredAt, Valid: true},
			Attributes: attrsJSON, UpdatedAt: incomingTS,
		}); err != nil {
			return OpResult{}, err
		}
		want := activityRowState{apiaryID: apiaryID.String(), typ: *data.Type, occurredAt: *data.OccurredAt, attributes: attrs, journeyID: journeyIDStringFromPtr(journeyID)}
		if err := writeActivityAuditLog(ctx, q, org, userID, op, history.ChangeCreate, activityRowState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	var existingAttrs map[string]any
	_ = json.Unmarshal(existing.Attributes, &existingAttrs)
	current := activityRowState{
		apiaryID: uuidString(existing.ApiaryID), typ: existing.Type,
		occurredAt: existing.OccurredAt.Time.Format(dateLayout), attributes: existingAttrs,
		journeyID: journeyIDString(existing.JourneyID),
		deletedAt: existing.DeletedAt,
	}
	// journey_id's tri-state presence (#387, journeyIDKeyPresent's own doc
	// comment) — delete ops carry no data at all, so there is no key to
	// detect there; mergeActivityOp's own delete branch never consults it.
	journeyIDPresent := op.Op != "delete" && journeyIDKeyPresent(op.Data)
	want, err := mergeActivityOp(current, op, data, journeyIDPresent)
	if err != nil {
		return OpResult{}, err
	}

	// Strictly-newer incoming wins (sync.md §4.1).
	if op.UpdatedAt.After(existing.UpdatedAt.Time) {
		apiaryUUID, err := uuid.Parse(want.apiaryID)
		if err != nil {
			return OpResult{}, err
		}
		occurredAtParsed, err := time.Parse(dateLayout, want.occurredAt)
		if err != nil {
			return OpResult{}, err
		}
		wantAttrsJSON, err := json.Marshal(want.attributes)
		if err != nil {
			return OpResult{}, err
		}
		wantJourneyID, err := journeyIDParamFromString(want.journeyID)
		if err != nil {
			return OpResult{}, err
		}
		if err := q.UpdateActivitySync(ctx, sqlcgen.UpdateActivitySyncParams{
			OrganizationID: org, ID: pgID,
			ApiaryID:   pgtype.UUID{Bytes: apiaryUUID, Valid: true},
			Type:       want.typ,
			OccurredAt: pgtype.Date{Time: occurredAtParsed, Valid: true},
			Attributes: wantAttrsJSON,
			JourneyID:  wantJourneyID,
			UpdatedAt:  incomingTS,
			DeletedAt:  want.deletedAt,
		}); err != nil {
			return OpResult{}, err
		}
		changeType := history.ChangeUpdate
		if op.Op == "delete" {
			changeType = history.ChangeDelete
		}
		if err := writeActivityAuditLog(ctx, q, org, userID, op, changeType, current, want); err != nil {
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
	if err := logActivityConflict(ctx, q, org, userID, op, existing); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

// mergeActivityOp computes the row an op would produce, given the current
// stored state (#40/#41/#387, mirrors apiaries' mergeOp). delete sets the
// tombstone and otherwise leaves the row's content untouched (§4.5). put
// and patch are both a FULL resubmit of type/occurred_at/attributes
// (validateActivityOp's doc comment — activities' edit form always sends
// the complete current state, unlike apiaries' true partial PATCH); the one
// difference between them is apiary_id (falls back to current.apiaryID when
// absent — an edit that doesn't touch it, the common case) and deletedAt:
// put is a full replace and so implicitly UNDELETES (mirrors apiaries' own
// "put" convention — a fresh create/resend represents the row's live
// content), while patch preserves whatever current.deletedAt already was.
//
// journeyID (#387) is the one column with GENUINE tri-state wire semantics
// (journeyIDKeyPresent's own doc comment) — journeyIDPresent (the caller's
// pre-computed presence check over the RAW op.Data, since data.JourneyID's
// *string can't distinguish absent from explicit null) drives it: key
// present with a UUID re-links; key present as `null` clears; key absent on
// a PATCH keeps current.journeyID (an edit that doesn't touch the
// attachment — the common case); key absent on a PUT clears too — a full
// resubmit that doesn't mention journey_id represents "this activity has no
// journey", exactly matching create's own convention (a create body with no
// journey_id inserts NULL, write.go's createActivity).
func mergeActivityOp(current activityRowState, op Op, data activityData, journeyIDPresent bool) (activityRowState, error) {
	if op.Op == "delete" {
		current.deletedAt = pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}
		return current, nil
	}
	// attributes falls back to current.attributes when absent, exactly like
	// apiaryID/typ/occurredAt below — a patch that doesn't carry attributes
	// (PowerSync's column diff omits unchanged columns, #378) must not wipe
	// them. Previously this always reset to an empty map absent an explicit
	// data.Attributes, silently discarding the stored attribute bag on any
	// patch that didn't happen to touch it.
	attrs := current.attributes
	if len(data.Attributes) > 0 {
		attrs = map[string]any{}
		if err := json.Unmarshal(data.Attributes, &attrs); err != nil {
			return activityRowState{}, err
		}
	}
	want := activityRowState{
		apiaryID:   current.apiaryID,
		typ:        current.typ,
		occurredAt: current.occurredAt,
		attributes: attrs,
		journeyID:  current.journeyID,
		deletedAt:  current.deletedAt,
	}
	if data.ApiaryID != nil {
		want.apiaryID = *data.ApiaryID
	}
	if data.Type != nil {
		want.typ = *data.Type
	}
	if data.OccurredAt != nil {
		want.occurredAt = *data.OccurredAt
	}
	switch {
	case journeyIDPresent && data.JourneyID != nil:
		parsed, err := uuid.Parse(*data.JourneyID)
		if err != nil {
			return activityRowState{}, err
		}
		want.journeyID = parsed.String()
	case journeyIDPresent: // present, value null -> explicit clear
		want.journeyID = ""
	case op.Op == "put": // absent on a full resubmit -> clear (create's own convention)
		want.journeyID = ""
	default: // absent on a patch -> keep the stored link untouched
		want.journeyID = current.journeyID
	}
	if op.Op == "put" {
		want.deletedAt = pgtype.Timestamptz{}
	}
	return want, nil
}

func writeActivityAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, before, after activityRowState) error {
	var oldFields map[string]any
	if changeType != history.ChangeCreate {
		oldFields = before.fields()
	}
	newFields := after.fields()
	if changeType == history.ChangeDelete {
		// #41: a tombstone's "after" is nil, not the row's still-live field
		// values — mirrors write.go's writeActivityAuditLogTx (the REST-path
		// counterpart) and apiaries/api/sync.go's own writeAuditLog.
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
		"journey_id":  journeyIDPtr(stored.JourneyID),
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
		EntityType:     entityTypeActivity,
		EntityID:       stored.ID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}
