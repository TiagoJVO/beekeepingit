// Package api (this file) — stock_declarations: the "Declaração de
// Existências" log (#298, FR-AP-10, triaged from D-19).
//
// WHAT A DECLARATION IS, AND WHAT IT IS NOT. Portugal requires beekeepers to
// declare their hive stock to DGAV annually (1–30 September) and again whenever
// the stock changes materially. A declaration is therefore a POINT-IN-TIME
// RECORD of what was declared on a date — emphatically NOT the live hive
// counter (FR-AP-7, D-2, D-20, counters.go): a counter answers "how many hives
// are here now" and moves with reality; a declaration must stay exactly what it
// said after reality moves on. Conflating the two would destroy the only thing
// the record exists for.
//
// SCOPED TO A DGAV REGISTRATION NUMBER, NOT TO AN APIARY. The real declaration
// covers a BEEKEEPER's whole holding, and DGAV issues one registration number
// per beekeeper (FR-AP-9). So a declaration is keyed by that number, and an
// organization covering several beekeepers files one declaration per number.
// The number is stored as a plain text VALUE rather than a reference: it is
// what the declaration was filed under, and must not shift retroactively if the
// organization's default or an apiary's override is later corrected.
//
// IDENTITY IS THE ROW ID, unlike apiary_counters. A counter is re-keyed
// server-side by (apiary_id, counter_type) because two devices creating "the
// hive counter of apiary X" mean the same row. Two devices creating a
// declaration mean two DIFFERENT declarations — an event record, like an apiary
// itself — so this file mirrors applyOp's plain-PK LWW + tombstone shape, not
// applyCounterOp's upsert.
//
// EVERYTHING HERE IS ADVISORY. The service stores and syncs declarations; the
// September window and the interim trigger are computed client-side for display
// only (client/lib/features/dgav/dgav_rules.dart), nothing is required, and the
// app submits nothing to DGAV/SICOA (D-19's research note §7 keeps that out of
// scope).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// entityTypeStockDeclaration is the sync-apply entity_type for
// apiaries.stock_declarations rows (#298) — a third entity_type the same batch
// endpoint accepts alongside apiary and apiary_counter, so one client
// transaction can mix all three.
const entityTypeStockDeclaration = "stock_declaration"

const (
	// maxDeclarationNotesLength bounds the optional free-text note on a
	// declaration. Shorter than an apiary's 10000-char notes on purpose: this
	// is a filing memo ("filed via the IFAP portal"), not a field journal, and
	// the cap matches the column CHECK (migration 00010).
	maxDeclarationNotesLength = 2000
	// maxDeclarationBreakdownEntries bounds the per-apiary snapshot array. An
	// organization with more apiaries than this is far outside anything the app
	// targets, and an unbounded array in a JSONB column is a
	// resource-exhaustion surface reachable from a single op.
	maxDeclarationBreakdownEntries = 1000
	// declaredOnLayout is the wire format for declared_on — a plain calendar
	// DATE, not a timestamp. A declaration is filed ON a day; carrying a
	// timezone-bearing instant would make "was this inside the 1–30 September
	// window" depend on the reader's zone, which is exactly the ambiguity the
	// DATE column exists to remove.
	declaredOnLayout = "2006-01-02"
)

// declarationData is the sync wire shape for an entityTypeStockDeclaration op's
// `data`, mirroring the client's local PowerSync column names verbatim
// (client/lib/core/sync/powersync_schema.dart) exactly as apiaryData does.
//
// Breakdown is json.RawMessage rather than a typed slice: the server stores the
// snapshot verbatim in a JSONB column and never interprets its contents — the
// client builds and renders it. It is still VALIDATED as a bounded JSON array
// of objects (validateDeclarationOp), so the column's own array CHECK cannot be
// tripped by a malformed op and a garbage blob cannot be smuggled in.
type declarationData struct {
	DgavRegistrationNumber *string         `json:"dgav_registration_number"`
	DeclaredOn             *string         `json:"declared_on"`
	TotalHiveCount         *int32          `json:"total_hive_count"`
	Breakdown              json.RawMessage `json:"breakdown"`
	Notes                  *string         `json:"notes"`
}

// declarationState is the mutable projection of a declaration the LWW logic
// reasons about — the declarations counterpart of rowState.
type declarationState struct {
	dgavNumber string
	declaredOn string // "" means unset; always the declaredOnLayout form
	total      int32
	breakdown  string // canonical JSON text; "[]" when unset
	notes      string // "" means unset
	deletedAt  pgtype.Timestamptz
}

func (a declarationState) sameAs(b declarationState) bool {
	return a.dgavNumber == b.dgavNumber && a.declaredOn == b.declaredOn &&
		a.total == b.total && a.breakdown == b.breakdown && a.notes == b.notes &&
		a.deletedAt.Valid == b.deletedAt.Valid
}

// fields projects a declarationState to the plain field map
// history.ComputeChange diffs (FR-HIS-1). Everything here is the beekeeper's
// own regulatory record — a registration number they are required to display at
// their apiaries anyway, hive counts, and their own memo — so none of it is
// personal data about a person (§7.3), and all of it belongs in the diff: the
// point of auditing a declaration is being able to see what changed about it.
func (a declarationState) fields() map[string]any {
	m := map[string]any{
		"dgav_registration_number": a.dgavNumber,
		"declared_on":              a.declaredOn,
		"total_hive_count":         a.total,
	}
	if a.breakdown != "" && a.breakdown != "[]" {
		m["breakdown"] = a.breakdown
	}
	if a.notes != "" {
		m["notes"] = a.notes
	}
	return m
}

// validateDeclarationOp validates an entityTypeStockDeclaration op (#298),
// enforcing exactly the rules applyDeclarationOp and the column CHECKs do.
//
// Unlike a counter, a declaration DOES accept delete: it is an independent
// record with its own lifecycle, so a mis-entered one must be removable and the
// tombstone must reach other devices (data-model.md's soft-delete convention).
func validateDeclarationOp(i int, op Op) []problem.FieldError {
	prefix := fmt.Sprintf("ops[%d]", i)
	var errs []problem.FieldError

	switch op.Op {
	case "put", "patch", "delete":
	default:
		errs = append(errs, problem.FieldError{Field: prefix + ".op", Code: "invalid", Message: "op must be put, patch or delete"})
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

	var data declarationData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "invalid", Message: "data must be an object"})
			return errs
		}
	}

	// A put is a full record: the two facts that make a declaration a
	// declaration — what was declared, and on what day — are both required.
	if op.Op == "put" {
		if data.DeclaredOn == nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.declared_on", Code: "required", Message: "declared_on is required"})
		}
		if data.TotalHiveCount == nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.total_hive_count", Code: "required", Message: "total_hive_count is required"})
		}
	}
	if data.DeclaredOn != nil {
		if _, err := time.Parse(declaredOnLayout, *data.DeclaredOn); err != nil {
			errs = append(errs, problem.FieldError{Field: prefix + ".data.declared_on", Code: "invalid", Message: "declared_on must be a date in YYYY-MM-DD form"})
		}
	}
	if data.TotalHiveCount != nil && *data.TotalHiveCount < 0 {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.total_hive_count", Code: "out_of_range", Message: "total_hive_count must be >= 0"})
	}
	if data.DgavRegistrationNumber != nil && len(*data.DgavRegistrationNumber) > maxDgavRegistrationNumberLength {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.dgav_registration_number", Code: "too_long", Message: "dgav_registration_number must be at most 50 characters"})
	}
	if data.Notes != nil && len(*data.Notes) > maxDeclarationNotesLength {
		errs = append(errs, problem.FieldError{Field: prefix + ".data.notes", Code: "too_long", Message: "notes must be at most 2000 characters"})
	}
	errs = append(errs, validateBreakdown(prefix, data.Breakdown)...)

	if op.Op == "patch" && data.DgavRegistrationNumber == nil && data.DeclaredOn == nil &&
		data.TotalHiveCount == nil && data.Breakdown == nil && data.Notes == nil {
		errs = append(errs, problem.FieldError{Field: prefix + ".data", Code: "required", Message: "patch must change at least one field"})
	}
	return errs
}

// validateBreakdown checks the per-apiary snapshot is a bounded JSON array of
// objects. The server never reads inside those objects — the client owns the
// shape — but "is an array", "is not enormous", and "holds objects, not
// scalars" are all things the database CHECK or a later reader would otherwise
// discover the hard way.
func validateBreakdown(prefix string, raw json.RawMessage) []problem.FieldError {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	field := prefix + ".data.breakdown"
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return []problem.FieldError{{Field: field, Code: "invalid", Message: "breakdown must be a JSON array"}}
	}
	if len(entries) > maxDeclarationBreakdownEntries {
		return []problem.FieldError{{Field: field, Code: "too_many", Message: fmt.Sprintf("breakdown must contain at most %d entries", maxDeclarationBreakdownEntries)}}
	}
	for _, entry := range entries {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(entry, &obj); err != nil {
			return []problem.FieldError{{Field: field, Code: "invalid", Message: "breakdown entries must be JSON objects"}}
		}
	}
	return nil
}

// mergeDeclarationOp computes the desired row from the stored one and the
// incoming op — the declarations counterpart of mergeOp. A put replaces the
// record (absent keys fall back to their zero/unset value); a patch overlays
// only what it carries; a delete keeps the content and sets the tombstone.
func mergeDeclarationOp(current declarationState, op Op, data declarationData) declarationState {
	switch op.Op {
	case "put":
		out := declarationState{breakdown: "[]"}
		applyDeclarationFields(&out, data)
		return out
	case "delete":
		current.deletedAt = pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}
		return current
	default: // patch
		applyDeclarationFields(&current, data)
		return current
	}
}

// applyDeclarationFields overlays whatever the op actually carried onto state —
// shared by mergeDeclarationOp's put and patch branches, which differ only in
// what they start from.
func applyDeclarationFields(state *declarationState, data declarationData) {
	if data.DgavRegistrationNumber != nil {
		state.dgavNumber = *data.DgavRegistrationNumber
	}
	if data.DeclaredOn != nil {
		state.declaredOn = *data.DeclaredOn
	}
	if data.TotalHiveCount != nil {
		state.total = *data.TotalHiveCount
	}
	if len(data.Breakdown) > 0 && string(data.Breakdown) != "null" {
		state.breakdown = string(data.Breakdown)
	}
	if data.Notes != nil {
		state.notes = *data.Notes
	}
}

// applyDeclarationOp applies one entityTypeStockDeclaration op (#298) — the
// stock_declarations counterpart of applyOp, and deliberately its shape rather
// than applyCounterOp's: a declaration's identity IS its client-generated row
// id (see this file's package doc), so this is plain-PK LWW with tombstones and
// a conflict log, not an upsert keyed by something else.
func applyDeclarationOp(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op) (OpResult, error) {
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return OpResult{}, err
	}
	pgID := pgtype.UUID{Bytes: id, Valid: true}
	incomingTS := pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true}

	var data declarationData
	if len(op.Data) > 0 {
		if err := json.Unmarshal(op.Data, &data); err != nil {
			return OpResult{}, err
		}
	}

	stored, err := q.GetStockDeclarationForUpdate(ctx, sqlcgen.GetStockDeclarationForUpdateParams{OrganizationID: org, ID: pgID})
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return OpResult{}, err
	}

	// No stored row: an offline create, or a delete of something this server
	// has never seen (nothing to tombstone — the delete is already true).
	if missing {
		if op.Op == "delete" {
			return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
		}
		want := mergeDeclarationOp(declarationState{breakdown: "[]"}, op, data)
		declaredOn, err := declaredOnParam(want.declaredOn)
		if err != nil {
			return OpResult{}, err
		}
		if err := q.InsertStockDeclaration(ctx, sqlcgen.InsertStockDeclarationParams{
			ID:                     pgID,
			OrganizationID:         org,
			DgavRegistrationNumber: want.dgavNumber,
			DeclaredOn:             declaredOn,
			TotalHiveCount:         want.total,
			Breakdown:              []byte(breakdownOrEmpty(want.breakdown)),
			Notes:                  notesParamFromState(want.notes),
			UpdatedAt:              incomingTS,
			DeletedAt:              want.deletedAt,
		}); err != nil {
			return OpResult{}, err
		}
		if err := writeDeclarationAuditLog(ctx, q, org, userID, op, history.ChangeCreate, declarationState{}, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	current := declarationState{
		dgavNumber: stored.DgavRegistrationNumber,
		declaredOn: formatDeclaredOn(stored.DeclaredOn),
		total:      stored.TotalHiveCount,
		breakdown:  breakdownOrEmpty(string(stored.Breakdown)),
		notes:      textOf(stored.Notes),
		deletedAt:  stored.DeletedAt,
	}
	want := mergeDeclarationOp(current, op, data)

	if op.UpdatedAt.After(stored.UpdatedAt.Time) {
		declaredOn, err := declaredOnParam(want.declaredOn)
		if err != nil {
			return OpResult{}, err
		}
		if err := q.UpdateStockDeclaration(ctx, sqlcgen.UpdateStockDeclarationParams{
			OrganizationID:         org,
			ID:                     pgID,
			DgavRegistrationNumber: want.dgavNumber,
			DeclaredOn:             declaredOn,
			TotalHiveCount:         want.total,
			Breakdown:              []byte(breakdownOrEmpty(want.breakdown)),
			Notes:                  notesParamFromState(want.notes),
			UpdatedAt:              incomingTS,
			DeletedAt:              want.deletedAt,
		}); err != nil {
			return OpResult{}, err
		}
		changeType := history.ChangeUpdate
		if op.Op == "delete" {
			changeType = history.ChangeDelete
		}
		if err := writeDeclarationAuditLog(ctx, q, org, userID, op, changeType, current, want); err != nil {
			return OpResult{}, err
		}
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}

	// Equal or older. Changing nothing is an idempotent re-send (applied, no
	// conflict); otherwise the server value stands and the loser is preserved
	// rather than dropped (§4.1/§4.2, history.md §6).
	if want.sameAs(current) {
		return OpResult{ID: op.ID, Op: op.Op, Result: resultApplied}, nil
	}
	if err := logDeclarationConflict(ctx, q, org, userID, op, stored); err != nil {
		return OpResult{}, err
	}
	return OpResult{ID: op.ID, Op: op.Op, Result: resultSuperseded}, nil
}

// declaredOnParam converts the wire's YYYY-MM-DD string to the pgtype.Date the
// column takes. An unparseable value cannot reach here through the sync
// endpoints (validateDeclarationOp rejects it first, sync.md §6.2), so a
// failure is a wiring bug worth surfacing as an error rather than silently
// storing a zero date.
func declaredOnParam(value string) (pgtype.Date, error) {
	if value == "" {
		return pgtype.Date{}, errors.New("stock declaration: declared_on is empty (validate should have rejected this op)")
	}
	t, err := time.Parse(declaredOnLayout, value)
	if err != nil {
		return pgtype.Date{}, fmt.Errorf("stock declaration: parse declared_on %q: %w", value, err)
	}
	return pgtype.Date{Time: t, Valid: true}, nil
}

// formatDeclaredOn renders a stored DATE back to the wire's YYYY-MM-DD form, so
// declarationState compares like with like (the LWW no-op check is a string
// comparison against what the op carried).
func formatDeclaredOn(d pgtype.Date) string {
	if !d.Valid {
		return ""
	}
	return d.Time.Format(declaredOnLayout)
}

// breakdownOrEmpty normalizes an absent/empty snapshot to the empty JSON array
// the column defaults to, so "no breakdown" has exactly one representation
// everywhere — in the column, in declarationState, and in the audit diff.
func breakdownOrEmpty(value string) string {
	if value == "" {
		return "[]"
	}
	return value
}

// writeDeclarationAuditLog is writeAuditLog's counterpart for a stock
// declaration (FR-HIS-1). entity_id is the declaration's own id — unlike a
// counter's audit row, which borrows its apiary's id because a counter has no
// stable id of its own.
func writeDeclarationAuditLog(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, changeType string, before, after declarationState) error {
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
		return fmt.Errorf("compute stock declaration change: %w", err)
	}
	changeJSON, err := json.Marshal(change)
	if err != nil {
		return err
	}
	id, err := uuid.Parse(op.ID)
	if err != nil {
		return err
	}
	return q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		OrganizationID: org,
		EntityType:     entityTypeStockDeclaration,
		EntityID:       pgtype.UUID{Bytes: id, Valid: true},
		ChangeType:     changeType,
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	})
}

// logDeclarationConflict is logConflict's counterpart for an LWW-losing
// declaration op: the losing offline edit is preserved rather than dropped
// (history.md §6, "LWW losers are not lost").
func logDeclarationConflict(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, userID string, op Op, stored sqlcgen.GetStockDeclarationForUpdateRow) error {
	winning, err := json.Marshal(map[string]any{
		"id":                       uuidString(stored.ID),
		"dgav_registration_number": stored.DgavRegistrationNumber,
		"declared_on":              formatDeclaredOn(stored.DeclaredOn),
		"total_hive_count":         stored.TotalHiveCount,
		"breakdown":                json.RawMessage(breakdownOrEmpty(string(stored.Breakdown))),
		"notes":                    textPtr(stored.Notes),
		"updated_at":               stored.UpdatedAt.Time,
		"deleted_at":               timePtr(stored.DeletedAt),
	})
	if err != nil {
		return err
	}
	losing, err := json.Marshal(op)
	if err != nil {
		return err
	}
	return q.InsertConflict(ctx, sqlcgen.InsertConflictParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		OrganizationID: org,
		EntityType:     entityTypeStockDeclaration,
		EntityID:       stored.ID,
		WinningPayload: winning,
		LosingPayload:  losing,
		Winner:         "server",
		ActorUserID:    parseActor(ctx, userID),
		OccurredAt:     pgtype.Timestamptz{Time: op.UpdatedAt, Valid: true},
	})
}
