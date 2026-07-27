// Package api holds the organizations service's HTTP surface: this file is
// the internal, east-west endpoint other services' shared auth middleware
// calls to resolve a user to its active membership (organization_id + role,
// auth.md section 5.1 steps 2-3, walking-skeleton.md section 5.2) -- never exposed through
// the gateway. The client-facing organization routes (organizations.go) are
// a separate concern; see that file's own package doc.
//
// Trust boundary note (tracked as #280): this endpoint takes the caller's
// user_id as a plain query parameter and trusts it, with "never exposed via
// the gateway" as its only stated guard -- there is no in-request check
// tying the value back to the calling service's own authenticated identity
// (e.g. mTLS peer identity or an internal-only JWT audience). This is a
// platform-wide pattern shared with identity's equivalent
// /internal/users/by-sub/{sub} endpoint, not something to fix unilaterally
// here -- see #280 for the tracked hardening item.
package api

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// MembershipResponse is the internal resolve payload other services consume.
type MembershipResponse struct {
	OrganizationID string `json:"organization_id"`
	Role           string `json:"role"`
}

// InternalRouter returns the /internal resolve routes, backed by pool. Mount
// it under "/internal" behind the OIDC authn middleware.
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
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get active membership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, r, http.StatusOK, MembershipResponse{
			OrganizationID: uuid.UUID(m.OrganizationID.Bytes).String(),
			Role:           m.Role,
		})
	}
}
