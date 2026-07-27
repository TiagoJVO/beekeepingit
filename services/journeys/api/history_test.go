package api

// Fast, pure-function unit tests for history.go's DTO mapping (#315,
// FR-HIS-1) — no DB/Docker dependency, mirroring apiaries/activities'
// history_test.go. The HTTP handler itself (getJourneyHistory: tenancy/404,
// the real combined audit_log+sync_conflict_log query) is covered by the
// containerized suite in main_test.go, since it needs a real Postgres.

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/journeys/store/sqlc/gen"
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
		EntityType:     "journey",
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
	if got.EntityType != "journey" {
		t.Errorf("EntityType = %q, want journey", got.EntityType)
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
	if got.OccurredAt == nil || !got.OccurredAt.Equal(occurredAt) {
		t.Errorf("OccurredAt = %v, want %v", got.OccurredAt, occurredAt)
	}
	if !got.RecordedAt.Equal(recordedAt) {
		t.Errorf("RecordedAt = %v, want %v", got.RecordedAt, recordedAt)
	}
	if len(got.ChangedFields) != 1 || got.ChangedFields[0] != "name" {
		t.Errorf("ChangedFields = %v, want [name]", got.ChangedFields)
	}
	if string(got.Change) != string(change) {
		t.Errorf("Change = %s, want %s", got.Change, change)
	}
}

// TestTimelineRowToDTO_SupersededRowWithNullActorAndTimestamp covers the
// sync_conflict_log side of the union: a losing offline edit may carry neither
// a resolvable actor nor a device timestamp, so actor_user_id and occurred_at
// are both NULL. Both must map to nil (not a zero-value UUID/time), keeping the
// REST shape identical to the client's local-store path (which preserves a true
// SQL NULL) — history.md §6 / the client history repository's documented
// invariant.
func TestTimelineRowToDTO_SupersededRowWithNullActorAndTimestamp(t *testing.T) {
	id := uuid.New()
	entityID := uuid.New()
	recordedAt := time.Date(2026, 7, 16, 11, 0, 0, 0, time.UTC)
	change := []byte(`{"winning_payload":{},"losing_payload":{},"winner":"server"}`)

	row := sqlcgen.ListEntityTimelineRow{
		ID:            pgtype.UUID{Bytes: id, Valid: true},
		EntityType:    "journey",
		EntityID:      pgtype.UUID{Bytes: entityID, Valid: true},
		EventKind:     history.EventSuperseded,
		ActorUserID:   pgtype.UUID{Valid: false},
		OccurredAt:    pgtype.Timestamptz{Valid: false},
		RecordedAt:    pgtype.Timestamptz{Time: recordedAt, Valid: true},
		ChangedFields: nil,
		Change:        change,
	}

	got := timelineRowToDTO(row)

	if got.EventKind != history.EventSuperseded {
		t.Errorf("EventKind = %q, want %q", got.EventKind, history.EventSuperseded)
	}
	if got.ActorUserID != nil {
		t.Errorf("ActorUserID = %v, want nil (unresolved actor)", got.ActorUserID)
	}
	if got.OccurredAt != nil {
		t.Errorf("OccurredAt = %v, want nil (a NULL device time must not render as the zero time)", got.OccurredAt)
	}
	if got.ChangedFields != nil {
		t.Errorf("ChangedFields = %v, want nil (only audit_log rows carry it)", got.ChangedFields)
	}
}

// TestHistoryEntryDTO_OmitsNilOptionalFields pins the wire contract the client
// depends on: a nil actor/occurred_at/changed_fields must be absent from (or
// null in) the JSON, never a fabricated zero value.
func TestHistoryEntryDTO_OmitsNilOptionalFields(t *testing.T) {
	dto := historyEntryDTO{
		ID:         uuid.New().String(),
		EntityType: "journey",
		EntityID:   uuid.New().String(),
		EventKind:  history.EventSuperseded,
		RecordedAt: time.Date(2026, 7, 16, 11, 0, 0, 0, time.UTC),
		Change:     json.RawMessage(`{}`),
	}

	b, err := json.Marshal(dto)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(b, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, k := range []string{"actor_user_id", "occurred_at", "changed_fields"} {
		if _, present := decoded[k]; present {
			t.Errorf("JSON contains %q, want it omitted when nil: %s", k, b)
		}
	}
}

func TestActorUserIDPtr(t *testing.T) {
	id := uuid.New()
	if got := actorUserIDPtr(pgtype.UUID{Bytes: id, Valid: true}); got == nil || *got != id.String() {
		t.Errorf("actorUserIDPtr(valid) = %v, want %q", got, id.String())
	}
	if got := actorUserIDPtr(pgtype.UUID{Valid: false}); got != nil {
		t.Errorf("actorUserIDPtr(NULL) = %v, want nil", got)
	}
}

func TestTimestampPtr(t *testing.T) {
	ts := time.Date(2026, 7, 16, 10, 0, 0, 0, time.UTC)
	if got := timestampPtr(pgtype.Timestamptz{Time: ts, Valid: true}); got == nil || !got.Equal(ts) {
		t.Errorf("timestampPtr(valid) = %v, want %v", got, ts)
	}
	// A NULL device time (the sync_conflict_log leg) must map to nil, never
	// Go's zero time serialized as a real-looking "0001-01-01T00:00:00Z".
	if got := timestampPtr(pgtype.Timestamptz{Valid: false}); got != nil {
		t.Errorf("timestampPtr(NULL) = %v, want nil", got)
	}
}
