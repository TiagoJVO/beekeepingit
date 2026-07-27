// Package api (this file) — the client-facing per-journey history read route
// (GET /v1/journeys/{journeyId}/history, FR-HIS-1, #315). It exposes over HTTP
// the combined audit_log + sync_conflict_log timeline journeys.sql's
// ListEntityTimeline query builds, the journeys counterpart of apiaries'
// (#60) and activities' own history endpoints.
//
// This is deliberately a thin, unpaginated read. The field client's primary
// history path is NOT this endpoint: journeys.audit_log and
// journeys.sync_conflict_log are replicated in full (not a bounded recent
// window — PowerSync Sync Rules can't express LIMIT, see
// infra/helm/beekeepingit/charts/powersync/values.yaml's bucket comment) to
// every synced device, so a synced client renders history entirely from its
// local tables, offline. This REST endpoint only matters as the online
// fallback for a device that hasn't synced yet (long-offline, or a fresh
// install). Given that fallback role, and that this is a low-write, single-org
// field domain where a per-entity timeline stays small, it intentionally does
// not add cursor pagination on top of what ListEntityTimeline already returns:
// the whole per-entity timeline, oldest first.
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
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/journeys/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// historyEntryDTO is one row of the combined per-entity timeline: either an
// audit_log change (event_kind = create/update/delete) or a sync_conflict_log
// LWW loss (event_kind = "superseded", mirroring history.EventSuperseded —
// spelled literally here since this DTO is JSON wire shape, not the Go
// constant). change is passed through as raw JSON: its shape differs by
// event_kind (the {field:{from,to}} audit delta vs the
// {winning_payload,losing_payload,winner} conflict payload), so the client
// branches on event_kind to interpret it — the same wire contract apiaries'
// and activities' history endpoints already expose.
type historyEntryDTO struct {
	ID            string          `json:"id"`
	EntityType    string          `json:"entity_type"`
	EntityID      string          `json:"entity_id"`
	EventKind     string          `json:"event_kind"`
	ActorUserID   *string         `json:"actor_user_id,omitempty"`
	OccurredAt    *time.Time      `json:"occurred_at,omitempty"`
	RecordedAt    time.Time       `json:"recorded_at"`
	ChangedFields []string        `json:"changed_fields,omitempty"`
	Change        json.RawMessage `json:"change"`
}

type historyListDTO struct {
	Data []historyEntryDTO `json:"data"`
}

// getJourneyHistory serves GET /v1/journeys/{journeyId}/history: org-scoped via
// requireOrg (never a client-supplied organization_id), 404 if the journey
// doesn't exist or belongs to another org. Existence+tenancy is checked via
// GetJourneyForUpdate rather than GetJourney: GetJourney filters deleted_at IS
// NULL, which would 404 this route for a soft-deleted journey even though its
// audit trail (including the delete event itself) still exists — the whole
// point of this endpoint is to expose that trail, so a deleted journey's
// history must stay reachable (FR-HIS-1). Reusing GetJourneyForUpdate (already
// used by updateJourney/deleteJourney and the sync-apply LWW compare for the
// same deleted_at-agnostic existence check) keeps the org-scoped lookup
// identical to every other journeys route, so this endpoint still enforces the
// same scope-hiding (ADR-0002) and can't be used to probe for a cross-org
// journey id's existence, mirroring apiaries' getApiaryHistory. The FOR UPDATE
// row lock this query carries is a no-op here (no explicit transaction wraps
// this single query, so pgx runs it and releases the lock in one round trip) —
// reusing the existing query avoids adding a third, near-duplicate
// existence-check query for one read route.
func getJourneyHistory(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, _, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "journeyId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("journey not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}
		q := sqlcgen.New(pool)

		if _, err := q.GetJourneyForUpdate(r.Context(), sqlcgen.GetJourneyForUpdateParams{OrganizationID: org, ID: pgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				problem.Write(w, r, problem.NotFound("journey not found"))
				return
			}
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get journey for history failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		rows, err := q.ListEntityTimeline(r.Context(), sqlcgen.ListEntityTimelineParams{
			OrganizationID: org,
			EntityType:     entityTypeJourney,
			EntityID:       pgID,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list journey history failed", slog.Any("error", err))
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

// timelineRowToDTO maps one ListEntityTimeline row to historyEntryDTO. Kept as
// its own pure function (no DB/HTTP dependency) so its null/type handling is
// unit-testable without a container, mirroring apiaries/activities' own
// history_test.go convention.
func timelineRowToDTO(row sqlcgen.ListEntityTimelineRow) historyEntryDTO {
	return historyEntryDTO{
		ID:            uuidString(row.ID),
		EntityType:    row.EntityType,
		EntityID:      uuidString(row.EntityID),
		EventKind:     row.EventKind,
		ActorUserID:   actorUserIDPtr(row.ActorUserID),
		OccurredAt:    timestampPtr(row.OccurredAt),
		RecordedAt:    row.RecordedAt.Time,
		ChangedFields: row.ChangedFields,
		Change:        json.RawMessage(row.Change),
	}
}

// actorUserIDPtr converts a nullable actor_user_id column to historyEntryDTO's
// *string — nil when the actor is unset (a conflict row applied without a
// resolvable caller). Never resolves to a name here — actor display-name
// resolution is a client-side join against the org roster, this DTO carries
// only the opaque internal id.
func actorUserIDPtr(id pgtype.UUID) *string {
	if !id.Valid {
		return nil
	}
	s := uuidString(id)
	return &s
}

// timestampPtr converts a nullable timestamptz column to historyEntryDTO's
// *time.Time, mirroring actorUserIDPtr's handling of a nullable UUID.
//
// The timeline UNIONs two tables whose occurred_at nullability DIFFERS:
// audit_log's is NOT NULL, but sync_conflict_log's is nullable (the losing
// offline edit may carry no device time), so the unioned column is nullable
// overall. A plain `row.OccurredAt.Time` would silently render that NULL as
// Go's zero time and serialize it as "0001-01-01T00:00:00Z" — a real-looking
// timestamp the client cannot distinguish from a genuine one, and which its
// local-store path (which preserves a true SQL NULL) would never produce.
// Returning nil keeps the REST and offline sources producing the identical
// shape, which the client's own history repository documents as an invariant.
// recorded_at needs no equivalent: it is NOT NULL on both tables.
func timestampPtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}
