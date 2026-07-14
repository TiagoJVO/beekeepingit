// Package api holds the apiaries service's HTTP surface: the client-facing
// REST endpoints (GET/POST/PATCH/DELETE /v1/apiaries[/{id}], apiaries.go +
// write.go, #31/FR-AP-1) and the internal sync validate/apply endpoints the
// write-back coordinator calls (walking-skeleton.md §5, sync.go). The field
// client never calls the REST write handlers directly — it is local-first
// through sync (§4.4); the REST writes serve online-only/direct callers.
package api

import (
	"encoding/json"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const entityTypeApiary = "apiary"

// entityTypeApiaryCounter is the sync-apply entity_type for apiary_counters
// rows (#256) — a second, parallel entity_type the same batch endpoint
// accepts alongside entityTypeApiary (sync.go's validateOp/applyOp branch on
// it), so a client transaction can freely mix apiary and counter ops in one
// push. Kept as its own constant (not inlined) since it appears in both
// sync.go (validate/apply) and history/conflict-log rows.
const entityTypeApiaryCounter = "apiary_counter"

// requireOrg is the tenancy-context hand-off point (FR-TEN-2, #30 AC:
// "a tenancy context is propagated from the validated token through the
// service layer to the data layer"): it pulls the org id
// authn.NewOrgResolver already derived server-side from the verified
// token + membership (never a client-supplied header/body/query value) off
// the request's Claims, parses it once, and every handler in this package
// passes the result straight into its sqlc query's OrganizationID param —
// the one point where "token claim" becomes "data-layer filter". The
// org-resolver middleware guarantees these are present; a missing value is
// a wiring bug, surfaced as 500.
func requireOrg(w http.ResponseWriter, r *http.Request) (orgID pgtype.UUID, userID string, ok bool) {
	claims, found := authn.FromContext(r.Context())
	if !found || claims.OrganizationID == "" {
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, "", false
	}
	parsed, err := uuid.Parse(claims.OrganizationID)
	if err != nil {
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, "", false
	}
	return pgtype.UUID{Bytes: parsed, Valid: true}, claims.UserID, true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

// textPtr converts a nullable pgtype.Text column (e.g. apiaries.notes) to the
// DTO's *string — nil when unset, matching Location's own
// present-vs-absent convention (apiaryDTO's `omitempty`).
func textPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	return &t.String
}
