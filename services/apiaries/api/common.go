// Package api holds the apiaries service's HTTP surface: the client-facing
// read endpoints (GET /v1/apiaries[/{id}]) and the internal sync
// validate/apply endpoints the write-back coordinator calls
// (walking-skeleton.md §5). Writes never arrive via a client-facing REST
// mutation in the slice — the field client is local-first through sync
// (§4.4); online REST write handlers are EPIC-02 (#31).
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
