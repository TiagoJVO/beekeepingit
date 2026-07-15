// Package api holds the identity service's HTTP surface. In the walking
// skeleton that is a single internal, east-west endpoint: resolve an OIDC
// subject to its identity.users row, called by the shared auth middleware of
// other services (auth.md §5.1 step 1, walking-skeleton.md
// §5.2). It is never exposed through the gateway.
package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/identity/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// UserResponse is the internal resolve payload other services consume.
type UserResponse struct {
	UserID  string `json:"user_id"`
	OidcSub string `json:"oidc_sub"`
	Name    string `json:"name"`
	Email   string `json:"email"`
	Locale  string `json:"locale"`
}

// InternalRouter returns the /internal resolve routes, backed by pool. Mount
// it under "/internal" behind the OIDC authn middleware.
func InternalRouter(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/users/by-sub/{sub}", getUserBySub(q))
	return r
}

func getUserBySub(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sub := chi.URLParam(r, "sub")
		if sub == "" {
			problem.Write(w, r, problem.ValidationFailed("sub path parameter is required"))
			return
		}

		u, err := q.GetUserByOidcSub(r.Context(), sub)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("no user for the given subject"))
			return
		}
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "users: get user by oidc sub failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, http.StatusOK, UserResponse{
			UserID:  uuid.UUID(u.ID.Bytes).String(),
			OidcSub: u.OidcSub,
			Name:    u.Name,
			Email:   u.Email,
			Locale:  u.Locale,
		})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
