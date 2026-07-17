// Package api (this file) — the client-facing per-activity history read
// route (GET /v1/activities/{activityId}/history, FR-HIS-1, #60). It exposes
// over HTTP the combined audit_log + sync_conflict_log timeline built by
// activities.sql's ListEntityTimeline query (history.md §6/§8), mirroring
// apiaries' own api/history.go (#60/#61) — see that file's doc comment for
// the full rationale (why it's deliberately unpaginated, why this is a
// fallback path rather than the field client's primary history read).
package api

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/activities/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// historyEntryDTO is one row of the combined per-entity timeline
// (history.md §3/§6) — same wire shape as apiaries' own historyEntryDTO
// (api/history.go), duplicated here rather than shared: each service's DTO
// is built from its own sqlcgen.ListEntityTimelineRow (a separate generated
// type per service/schema), and there is no shared HTTP-DTO package this
// repo's services import from for client-facing shapes (services/shared is
// infra-only, per its own README).
type historyEntryDTO struct {
	ID            string          `json:"id"`
	EntityType    string          `json:"entity_type"`
	EntityID      string          `json:"entity_id"`
	EventKind     string          `json:"event_kind"`
	ActorUserID   *string         `json:"actor_user_id,omitempty"`
	OccurredAt    time.Time       `json:"occurred_at"`
	RecordedAt    time.Time       `json:"recorded_at"`
	ChangedFields []string        `json:"changed_fields,omitempty"`
	Change        json.RawMessage `json:"change"`
}

type historyListDTO struct {
	Data []historyEntryDTO `json:"data"`
}

// getActivityHistory serves GET /v1/activities/{activityId}/history:
// org-scoped via requireOrg (never a client-supplied organization_id), 404 if
// the activity doesn't exist, is soft-deleted, or belongs to another org —
// reusing GetActivity's own existence+tenancy check, the same org-scoped
// lookup every other activities route already uses, so this endpoint can't
// be used to probe for a cross-org activity id's existence. This closes the
// same CRITICAL cross-org IDOR class this service's edit/delete paths were
// already carrying (#284/#39, and this task's own explicit "do not regress"
// note) — for a brand-new route, the guard is built in from the start rather
// than added as a follow-up fix.
func getActivityHistory(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, _, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "activityId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("activity not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		if _, err := q.GetActivity(r.Context(), sqlcgen.GetActivityParams{OrganizationID: org, ID: pgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				problem.Write(w, r, problem.NotFound("activity not found"))
				return
			}
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get activity for history failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		rows, err := q.ListEntityTimeline(r.Context(), sqlcgen.ListEntityTimelineParams{
			OrganizationID: org,
			EntityType:     entityTypeActivity,
			EntityID:       pgID,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list activity history failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		data := make([]historyEntryDTO, 0, len(rows))
		for _, row := range rows {
			data = append(data, timelineRowToDTO(row))
		}
		writeJSON(w, r, http.StatusOK, historyListDTO{Data: data})
	}
}

// timelineRowToDTO maps one ListEntityTimeline row to historyEntryDTO. Kept
// as its own pure function (no DB/HTTP dependency) so its null/type handling
// is unit-testable without a container, mirroring apiaries' identical helper
// and this package's types_test.go/validate_test.go convention for pure
// logic.
func timelineRowToDTO(row sqlcgen.ListEntityTimelineRow) historyEntryDTO {
	return historyEntryDTO{
		ID:            uuidString(row.ID),
		EntityType:    row.EntityType,
		EntityID:      uuidString(row.EntityID),
		EventKind:     row.EventKind,
		ActorUserID:   actorUserIDPtr(row.ActorUserID),
		OccurredAt:    row.OccurredAt.Time,
		RecordedAt:    row.RecordedAt.Time,
		ChangedFields: row.ChangedFields,
		Change:        json.RawMessage(row.Change),
	}
}

// actorUserIDPtr converts a nullable actor_user_id column to
// historyEntryDTO's *string — nil when the actor is unset, mirroring
// write.go's journeyIDPtr convention for a nullable pgtype.UUID. Never
// resolves to a name here — actor display-name resolution is a client-side
// join against the org roster (history.md §7.3/§8), this DTO carries only
// the opaque internal id.
func actorUserIDPtr(id pgtype.UUID) *string {
	if !id.Valid {
		return nil
	}
	s := uuidString(id)
	return &s
}
