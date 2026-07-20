// Package api (this file) — the client-facing per-apiary history read route
// (GET /v1/apiaries/{apiaryId}/history, FR-HIS-1, #60). It exposes over HTTP
// the combined audit_log + sync_conflict_log timeline that apiaries.sql's
// ListEntityTimeline query already builds (#61, history.md §6/§8) — that
// query was typed groundwork with no HTTP surface until now (its own doc
// comment says so explicitly).
//
// This is deliberately a thin, unpaginated read. The field client's primary
// history path is NOT this endpoint: apiaries.audit_log and
// apiaries.sync_conflict_log are already replicated in full (not a bounded
// recent window — PowerSync Sync Rules can't express LIMIT, see
// infra/helm/beekeepingit/charts/powersync/values.yaml's bucket comment) to
// every synced device, so a synced client renders history entirely from its
// local tables, offline (history.md §6 "recent history is offline-viewable").
// This REST endpoint only matters as the online fallback for a device that
// hasn't synced yet (long-offline, or a fresh install) — history.md §6 "deep
// history is an online query". Given that fallback role, and that this is a
// low-write, single-org field domain (Context C-1) where a per-entity
// timeline stays small, it intentionally does not add cursor pagination on
// top of what ListEntityTimeline (#61) already returns: the whole per-entity
// timeline, oldest first.
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

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// historyEntryDTO is one row of the combined per-entity timeline
// (history.md §3/§6): either an audit_log change (event_kind =
// create/update/delete) or a sync_conflict_log LWW loss (event_kind =
// history.EventSuperseded — "superseded" — mirrored as a literal here since
// this DTO is JSON wire shape, not the Go constant itself). change is passed
// through as raw JSON: its shape differs by event_kind (§3's {field:{from,to}}
// delta vs §4.2's {winning_payload,losing_payload,winner} conflict payload),
// so the client is expected to branch on event_kind to interpret it, exactly
// as ListEntityTimeline's own doc comment already establishes for the Go
// caller.
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

// getApiaryHistory serves GET /v1/apiaries/{apiaryId}/history: org-scoped via
// requireOrg (never a client-supplied organization_id), 404 if the apiary
// doesn't exist or belongs to another org. Existence+tenancy is checked via
// GetApiaryForUpdate rather than GetApiary: GetApiary filters deleted_at IS
// NULL, which would 404 this route for a soft-deleted apiary even though its
// audit trail (including the delete event itself) still exists — the whole
// point of this endpoint is to expose that trail, so a deleted apiary's
// history must stay reachable (FR-HIS-1). Reusing GetApiaryForUpdate
// (already used by updateApiary/deleteApiary for the same deleted_at-agnostic
// existence check) keeps the org-scoped lookup identical to every other
// apiaries route, so this endpoint still enforces the same scope-hiding
// (ADR-0002) and can't be used to probe for a cross-org apiary id's
// existence, mirroring the CRITICAL cross-org carry-over fix activities
// closed for its own REST surface (#284/#39). The FOR UPDATE row lock this
// query carries is a no-op for this handler's purposes (no explicit
// transaction wraps this single query, so pgx runs it and releases the lock
// in one round trip) — reusing the existing query avoids adding a third,
// near-duplicate existence-check query for one read route.
func getApiaryHistory(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, _, ok := requireOrg(w, r)
		if !ok {
			return
		}
		id, err := uuid.Parse(chi.URLParam(r, "apiaryId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("apiary not found"))
			return
		}
		pgID := pgtype.UUID{Bytes: id, Valid: true}

		if _, err := q.GetApiaryForUpdate(r.Context(), sqlcgen.GetApiaryForUpdateParams{OrganizationID: org, ID: pgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				problem.Write(w, r, problem.NotFound("apiary not found"))
				return
			}
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get apiary for history failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		rows, err := q.ListEntityTimeline(r.Context(), sqlcgen.ListEntityTimelineParams{
			OrganizationID: org,
			EntityType:     entityTypeApiary,
			EntityID:       pgID,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list apiary history failed", slog.Any("error", err))
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
// is unit-testable without a container, matching this package's
// validate_test.go/geo_test.go convention for pure logic.
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

// actorUserIDPtr converts a nullable actor_user_id column to
// historyEntryDTO's *string — nil when the actor is unset (history.md §3
// allows a null actor on rows applied without a resolvable caller, mirroring
// activities' api/write.go journeyIDPtr convention for a nullable
// pgtype.UUID). Never resolves to a name here — actor display-name
// resolution is a client-side join against the org roster (history.md §7.3/§8),
// this DTO carries only the opaque internal id.
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
