// Package api — client-facing profile routes (FR-ONB-1, #25). Unlike
// users.go's /internal resolve route, these sit behind the gateway at /v1 and
// are consumed directly by the client app once a user has authenticated but
// before any organization exists (auth.md §7, walking-skeleton.md §4.5). They
// therefore run behind authn.NewMiddleware only — no org resolver, since
// NewOrgResolver 403s a caller with no active membership yet, which every
// brand-new user is by definition.
//
// History recording (FR-HIS-1) for profile create/update is explicitly
// deferred — EPIC-07's audit log isn't built yet. Tracked in
// https://github.com/TiagoJVO/beekeepingit/issues/165; this is the seam where
// an audit write would go once that lands.
package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/identity/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const (
	maxNameLength  = 200
	maxEmailLength = 320 // RFC 5321 upper bound
)

var emailPattern = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

// ProfileResponse is the client-facing profile shape
// (contracts/openapi/identity.openapi.yaml's Profile schema).
// ProfileComplete is computed on every response, never stored, so it can
// never drift from the name/email it's derived from.
type ProfileResponse struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	Email           string    `json:"email"`
	Locale          string    `json:"locale"`
	ProfileComplete bool      `json:"profile_complete"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// profileUpdateRequest is the PATCH /v1/profile request body
// (ProfileUpdate schema) — every field optional, partial update semantics.
type profileUpdateRequest struct {
	Name   *string `json:"name"`
	Email  *string `json:"email"`
	Locale *string `json:"locale"`
}

// PublicRouter returns the client-facing /v1 profile routes, backed by pool.
// Mount it under "/v1" behind authn.NewMiddleware only (no org resolver — see
// package doc).
func PublicRouter(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/profile", getProfile(q))
	r.Patch("/profile", updateProfile(q))
	return r
}

func getProfile(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := authn.FromContext(r.Context())
		if !ok {
			problem.Write(w, r, problem.Internal())
			return
		}

		u, err := q.UpsertUserOnFirstSeen(r.Context(), sqlcgen.UpsertUserOnFirstSeenParams{
			ID:          pgtype.UUID{Bytes: uuid.New(), Valid: true},
			KeycloakSub: claims.Sub,
		})
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, http.StatusOK, toProfileResponse(u))
	}
}

func updateProfile(q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := authn.FromContext(r.Context())
		if !ok {
			problem.Write(w, r, problem.Internal())
			return
		}

		var body profileUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		if body.Name == nil && body.Email == nil && body.Locale == nil {
			problem.Write(w, r, problem.ValidationFailed("at least one field is required"))
			return
		}

		var fieldErrs []problem.FieldError
		params := sqlcgen.UpdateUserProfileParams{KeycloakSub: claims.Sub}

		if body.Name != nil {
			name := strings.TrimSpace(*body.Name)
			switch {
			case name == "":
				fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
			case len(name) > maxNameLength:
				fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
			default:
				params.SetName = true
				params.Name = name
			}
		}

		if body.Email != nil {
			email := strings.TrimSpace(*body.Email)
			switch {
			case email == "":
				fieldErrs = append(fieldErrs, problem.FieldError{Field: "email", Code: "required", Message: "email must not be empty"})
			case len(email) > maxEmailLength || !emailPattern.MatchString(email):
				fieldErrs = append(fieldErrs, problem.FieldError{Field: "email", Code: "invalid", Message: "email must be a valid email address"})
			default:
				params.SetEmail = true
				params.Email = email
			}
		}

		if body.Locale != nil {
			locale := strings.TrimSpace(*body.Locale)
			if locale == "" {
				fieldErrs = append(fieldErrs, problem.FieldError{Field: "locale", Code: "required", Message: "locale must not be empty"})
			} else {
				params.SetLocale = true
				params.Locale = locale
			}
		}

		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// The row is normally guaranteed to exist by the time a client can
		// PATCH (onboarding always does a GET, which get-or-creates it,
		// first) — but UPDATE ... RETURNING matching zero rows is still
		// handled explicitly (pgx.ErrNoRows) rather than folded into the
		// generic 500 branch, since "no such profile yet" is a legitimate,
		// distinguishable case, not a server fault.
		//
		// History write (FR-HIS-1) belongs here once EPIC-07 lands (#165) —
		// this is the seam: after a successful update, before responding.
		u, err := q.UpdateUserProfile(r.Context(), params)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("no profile exists yet for the caller — GET /v1/profile first"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, http.StatusOK, toProfileResponse(u))
	}
}

func toProfileResponse(u sqlcgen.IdentityUser) ProfileResponse {
	return ProfileResponse{
		ID:              uuid.UUID(u.ID.Bytes).String(),
		Name:            u.Name,
		Email:           u.Email,
		Locale:          u.Locale,
		ProfileComplete: u.Name != "" && u.Email != "",
		CreatedAt:       u.CreatedAt.Time,
		UpdatedAt:       u.UpdatedAt.Time,
	}
}
