package api

// Fast, pure-function unit tests for the history.go DTO mapping (#60,
// FR-HIS-1) — no DB/Docker dependency, mirrors validate_test.go's convention.
// The HTTP handler itself (getApiaryHistory: tenancy/404, the real combined
// audit_log+sync_conflict_log query) is covered by the containerized suite in
// main_test.go, since it needs a real Postgres.

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

func TestTimelineRowToDTO_AuditRowWithActor(t *testing.T) {
	id := uuid.New()
	entityID := uuid.New()
	actorID := uuid.New()
	occurredAt := time.Date(2026, 7, 16, 10, 0, 0, 0, time.UTC)
	recordedAt := time.Date(2026, 7, 16, 10, 0, 5, 0, time.UTC)
	change := []byte(`{"name":{"from":"A","to":"B"}}`)

	row := sqlcgen.ListEntityTimelineRow{
		ID:             pgtype.UUID{Bytes: id, Valid: true},
		OrganizationID: pgtype.UUID{Valid: true},
		EntityType:     "apiary",
		EntityID:       pgtype.UUID{Bytes: entityID, Valid: true},
		EventKind:      history.ChangeUpdate,
		ActorUserID:    pgtype.UUID{Bytes: actorID, Valid: true},
		OccurredAt:     pgtype.Timestamptz{Time: occurredAt, Valid: true},
		RecordedAt:     pgtype.Timestamptz{Time: recordedAt, Valid: true},
		ChangedFields:  []string{"name"},
		Change:         change,
	}

	got := timelineRowToDTO(row)

	if got.ID != id.String() {
		t.Errorf("ID = %q, want %q", got.ID, id.String())
	}
	if got.EntityType != "apiary" {
		t.Errorf("EntityType = %q, want apiary", got.EntityType)
	}
	if got.EntityID != entityID.String() {
		t.Errorf("EntityID = %q, want %q", got.EntityID, entityID.String())
	}
	if got.EventKind != history.ChangeUpdate {
		t.Errorf("EventKind = %q, want %q", got.EventKind, history.ChangeUpdate)
	}
	if got.ActorUserID == nil || *got.ActorUserID != actorID.String() {
		t.Errorf("ActorUserID = %v, want %q", got.ActorUserID, actorID.String())
	}
	if !got.OccurredAt.Equal(occurredAt) {
		t.Errorf("OccurredAt = %v, want %v", got.OccurredAt, occurredAt)
	}
	if !got.RecordedAt.Equal(recordedAt) {
		t.Errorf("RecordedAt = %v, want %v", got.RecordedAt, recordedAt)
	}
	if len(got.ChangedFields) != 1 || got.ChangedFields[0] != "name" {
		t.Errorf("ChangedFields = %v, want [name]", got.ChangedFields)
	}
	var gotChange map[string]any
	if err := json.Unmarshal(got.Change, &gotChange); err != nil {
		t.Fatalf("unmarshal Change: %v", err)
	}
	if _, ok := gotChange["name"]; !ok {
		t.Errorf("Change = %s, want a name field", got.Change)
	}
}

func TestTimelineRowToDTO_SupersededRowHasNoActorAndNoChangedFields(t *testing.T) {
	// A sync_conflict_log-derived row: event_kind is the literal "superseded"
	// (history.EventSuperseded), changed_fields is always NULL (only
	// audit_log rows carry it, per ListEntityTimeline's own UNION shape),
	// and — the case this test pins — an unresolved/absent actor must come
	// through as a nil pointer, never an empty-string placeholder that could
	// be confused with a real (if malformed) id.
	row := sqlcgen.ListEntityTimelineRow{
		ID:            pgtype.UUID{Bytes: uuid.New(), Valid: true},
		EntityType:    "apiary",
		EntityID:      pgtype.UUID{Bytes: uuid.New(), Valid: true},
		EventKind:     history.EventSuperseded,
		ActorUserID:   pgtype.UUID{Valid: false},
		OccurredAt:    pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
		RecordedAt:    pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
		ChangedFields: nil,
		Change:        []byte(`{"winner":"server"}`),
	}

	got := timelineRowToDTO(row)

	if got.EventKind != history.EventSuperseded {
		t.Errorf("EventKind = %q, want %q", got.EventKind, history.EventSuperseded)
	}
	if got.ActorUserID != nil {
		t.Errorf("ActorUserID = %v, want nil (unresolved actor)", *got.ActorUserID)
	}
	if got.ChangedFields != nil {
		t.Errorf("ChangedFields = %v, want nil", got.ChangedFields)
	}
}

func TestActorUserIDPtr(t *testing.T) {
	if got := actorUserIDPtr(pgtype.UUID{Valid: false}); got != nil {
		t.Errorf("actorUserIDPtr(invalid) = %v, want nil", *got)
	}
	id := uuid.New()
	got := actorUserIDPtr(pgtype.UUID{Bytes: id, Valid: true})
	if got == nil || *got != id.String() {
		t.Errorf("actorUserIDPtr(valid) = %v, want %q", got, id.String())
	}
}
