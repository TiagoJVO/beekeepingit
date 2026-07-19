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
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/identity/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// maxUserNameIDs bounds one GET /internal/users/names batch — the organizations
// service resolves one page of its member roster per call, and that page is
// itself clamped to maxPageLimit=200 (api/invitations.go's parsePage), so 200
// covers a full page with no truncation. A request over the cap is a 422, not
// a silent trim, so a caller never believes it resolved names it didn't.
const maxUserNameIDs = 200

// UserResponse is the internal resolve payload other services consume.
type UserResponse struct {
	UserID  string `json:"user_id"`
	OidcSub string `json:"oidc_sub"`
	Name    string `json:"name"`
	Email   string `json:"email"`
	Locale  string `json:"locale"`
}

// UserNameResponse is the internal batch name-resolve payload: user_id ->
// display name only, never email (FR-TEN-2: names are org-shareable app data,
// the IdP-verified email is not). Consumed by organizations' member-names
// endpoint (#44 follow-up).
type UserNameResponse struct {
	UserID string `json:"user_id"`
	Name   string `json:"name"`
}

type userNameListResponse struct {
	Data []UserNameResponse `json:"data"`
}

// InternalRouter returns the /internal resolve routes, backed by pool. Mount
// it under "/internal" behind the OIDC authn middleware.
func InternalRouter(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/users/by-sub/{sub}", getUserBySub(q))
	r.Get("/users/names", getUsersByNames(q))
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

// getUsersByNames resolves a batch of app user_ids to their display names —
// the internal half of the member-name capability (#44 follow-up): the
// organizations service knows WHICH user_ids belong to the caller's org (and
// authorizes that the caller may see them), then calls this to turn them into
// names, since names live here, not in organizations' membership rows
// (service-decomposition.md §4 rule 3 — cross-context composition by ID).
//
// ids is a comma-separated list of UUIDs in the query string. Ids with no
// identity.users row are simply omitted from the response (a removed or
// never-provisioned user); the caller falls back to a short id fragment for
// those. Ordering is not guaranteed — the caller keys by user_id.
//
// Trust boundary: like /users/by-sub and organizations' own
// /internal/memberships/active, this trusts its input and relies on "never
// exposed through the gateway" as its guard (tracked platform-wide as #280).
func getUsersByNames(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		raw := strings.TrimSpace(r.URL.Query().Get("ids"))
		if raw == "" {
			problem.Write(w, r, problem.ValidationFailed("ids query parameter is required",
				problem.FieldError{Field: "ids", Code: "required", Message: "ids is required"}))
			return
		}

		parts := strings.Split(raw, ",")
		if len(parts) > maxUserNameIDs {
			problem.Write(w, r, problem.ValidationFailed("too many ids in one request",
				problem.FieldError{Field: "ids", Code: "too_many", Message: "at most 200 ids per request"}))
			return
		}
		ids := make([]pgtype.UUID, 0, len(parts))
		for _, p := range parts {
			uid, err := uuid.Parse(strings.TrimSpace(p))
			if err != nil {
				problem.Write(w, r, problem.ValidationFailed("every id must be a UUID",
					problem.FieldError{Field: "ids", Code: "invalid", Message: "must be a comma-separated list of UUIDs"}))
				return
			}
			ids = append(ids, pgtype.UUID{Bytes: uid, Valid: true})
		}

		rows, err := q.GetUsersByNames(r.Context(), ids)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "users: get users by names failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}

		data := make([]UserNameResponse, 0, len(rows))
		for _, row := range rows {
			data = append(data, UserNameResponse{
				UserID: uuid.UUID(row.ID.Bytes).String(),
				Name:   row.Name,
			})
		}
		writeJSON(w, http.StatusOK, userNameListResponse{Data: data})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
