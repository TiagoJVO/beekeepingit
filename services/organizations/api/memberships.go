// Package api holds the organizations service's HTTP surface. In the walking
// skeleton that is a single internal, east-west endpoint: resolve a user to
// its active membership (organization_id + role), called by the shared auth
// middleware of other services (auth.md §5.1 steps 2–3, walking-skeleton.md
// §5.2). It is never exposed through the gateway.
package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// MembershipResponse is the internal resolve payload other services consume.
type MembershipResponse struct {
	OrganizationID string `json:"organization_id"`
	Role           string `json:"role"`
}

// InternalRouter returns the /internal resolve routes, backed by pool. Mount
// it under "/internal" behind the Keycloak authn middleware.
func InternalRouter(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/memberships/active", getActiveMembership(q))
	return r
}

func getActiveMembership(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		raw := r.URL.Query().Get("user_id")
		if raw == "" {
			problem.Write(w, r, problem.ValidationFailed("user_id query parameter is required",
				problem.FieldError{Field: "user_id", Code: "required", Message: "user_id is required"}))
			return
		}
		uid, err := uuid.Parse(raw)
		if err != nil {
			problem.Write(w, r, problem.ValidationFailed("user_id must be a UUID",
				problem.FieldError{Field: "user_id", Code: "invalid", Message: "must be a UUID"}))
			return
		}

		m, err := q.GetActiveMembershipByUser(r.Context(), pgtype.UUID{Bytes: uid, Valid: true})
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("no active membership for the given user"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, http.StatusOK, MembershipResponse{
			OrganizationID: uuid.UUID(m.OrganizationID.Bytes).String(),
			Role:           m.Role,
		})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
