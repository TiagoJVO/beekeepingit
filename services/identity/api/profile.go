// Package api — client-facing profile routes (FR-ONB-1, #25). Unlike
// users.go's /internal resolve route, these sit behind the gateway at /v1 and
// are consumed directly by the client app once a user has authenticated but
// before any organization exists (auth.md §7, walking-skeleton.md
// §4.5). They therefore run behind authn.NewMiddleware only — no org
// resolver, since NewOrgResolver 403s a caller with no active membership
// yet, which every brand-new user is by definition.
//
// History recording (FR-HIS-1, #165): a create-on-first-seen (getProfile) or
// update (updateProfile) writes one identity.audit_log row in the SAME local
// transaction as the identity.users write (history.md §4, mirroring
// #59's apiaries.audit_log pattern in services/apiaries/api/sync.go) — both
// now run inside an explicit pool.Begin/Commit rather than the bare pooled
// query the walking skeleton originally used, specifically so the domain
// write and its audit row commit together or not at all.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/identity/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// entityTypeProfile is identity.audit_log's entity_type discriminator for
// identity.users rows (history.md §3's polymorphic entity_type
// column).
const entityTypeProfile = "profile"

const maxNameLength = 200

// ProfileResponse is the client-facing profile shape
// (contracts/openapi/identity.openapi.yaml's Profile schema).
// ProfileComplete is computed on every response, never stored, so it can
// never drift from the name it's derived from.
//
// Email/EmailVerified are served from the CALLER'S TOKEN, not from the row:
// the identity provider owns the address (D-7), and identity.users.email is
// only a best-effort cache seeded once at first sight. The two can therefore
// legitimately differ — after an address change at the provider, the token is
// right and the cache is stale — so the authoritative value is the one
// returned here (#365 follow-up, FR-ONB-1).
type ProfileResponse struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	Email           string    `json:"email"`
	EmailVerified   bool      `json:"email_verified"`
	Locale          string    `json:"locale"`
	ProfileComplete bool      `json:"profile_complete"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// profileUpdateRequest is the PATCH /v1/profile request body
// (ProfileUpdate schema) — every field optional, partial update semantics.
//
// Email is NOT part of that schema any more (#365 follow-up): it is retained
// here purely so a body that still carries one can be DETECTED and refused
// with an explicit 422 `read_only`, rather than silently ignored — a silent
// ignore would let a client believe it saved an address it did not.
type profileUpdateRequest struct {
	Name   *string `json:"name"`
	Email  *string `json:"email"`
	Locale *string `json:"locale"`
}

// PublicRouter returns the client-facing /v1 profile routes, backed by pool.
// Mount it under "/v1" behind authn.NewMiddleware only (no org resolver —
// see package doc). pool (not just a *sqlcgen.Queries) is threaded through
// so getProfile/updateProfile can open the local transaction their audit
// write needs (history.md §4).
func PublicRouter(pool *pgxpool.Pool) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Get("/profile", getProfile(pool, q))
	r.Patch("/profile", updateProfile(pool, q))
	return r
}

// profileFields projects a profile row to the plain field map
// history.ComputeChange diffs — only the profile's own scalar fields, never
// denormalized personal data belonging to anyone but the row's own subject
// (§7.3 forbids embedding OTHER users'/actors' PII in a change
// payload; this entity's own name/email are the fields the change is about,
// same as apiaries' rowState.fields()).
func profileFields(u sqlcgen.IdentityUser) map[string]any {
	return map[string]any{"name": u.Name, "email": u.Email, "locale": u.Locale}
}

// writeProfileAuditLog appends one history.md §3 row for an applied
// profile create/update, in the same local transaction as the
// identity.users write (§4). organization_id is always NULL —
// identity.users is global, not org-owned (history.md §9). Every
// failure is wrapped with context (fmt.Errorf("...: %w", err)), matching
// this module's own error-wrapping convention used in main.go and
// store/seed.go.
func writeProfileAuditLog(ctx context.Context, q *sqlcgen.Queries, entityID pgtype.UUID, actorUserID pgtype.UUID, changeType string, before, after sqlcgen.IdentityUser) error {
	var oldFields map[string]any
	if changeType != history.ChangeCreate {
		oldFields = profileFields(before)
	}
	changedFields, change, err := history.ComputeChange(changeType, oldFields, profileFields(after))
	if err != nil {
		return fmt.Errorf("compute profile change: %w", err)
	}

	changeJSON, err := json.Marshal(change)
	if err != nil {
		return fmt.Errorf("marshal profile audit change payload: %w", err)
	}

	if err := q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		OrganizationID: pgtype.UUID{Valid: false}, // identity.users is global (history.md §9)
		EntityType:     entityTypeProfile,
		EntityID:       entityID,
		ChangeType:     changeType,
		ActorUserID:    actorUserID,
		OccurredAt:     pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
		ChangedFields:  changedFields,
		Change:         changeJSON,
	}); err != nil {
		return fmt.Errorf("insert profile audit log: %w", err)
	}
	return nil
}

// createProfileOnFirstSeen performs the first-seen create: the
// identity.users insert and its identity.audit_log row commit together or
// not at all (history.md §4). Extracted out of getProfile
// (code-review HIGH #3) so the handler itself only orchestrates the
// HTTP-level flow. Every internal failure is logged here, via the
// request-scoped logger carried in ctx, before being returned — the caller
// only ever surfaces a generic 500 to the client, so this is the one place
// the real cause is recorded (auth-adjacent service: failures must never be
// invisible).
// seedParamsFromClaims maps a verified token onto the first-seen INSERT.
// Pure, so the seeding rules are unit-testable without a database.
//
// The email is seeded ONLY when the token reports it verified: an unverified
// address must never enter identity.users.email, or the cache would carry a
// value no one has proven control of. The name carries whatever the provider
// emitted, including nothing — an empty name simply leaves the profile
// incomplete and the client prompts for it (#365 follow-up, FR-ONB-1).
func seedParamsFromClaims(id pgtype.UUID, claims authn.Claims) sqlcgen.UpsertUserOnFirstSeenParams {
	params := sqlcgen.UpsertUserOnFirstSeenParams{
		ID:      id,
		OidcSub: claims.Sub,
		Name:    strings.TrimSpace(claims.Name),
	}
	if claims.EmailVerified {
		params.Email = strings.TrimSpace(claims.Email)
	}
	return params
}

func createProfileOnFirstSeen(ctx context.Context, pool *pgxpool.Pool, q *sqlcgen.Queries, claims authn.Claims) (sqlcgen.IdentityUser, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "profile: begin first-seen create transaction failed", "error", err)
		return sqlcgen.IdentityUser{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after a successful Commit
	txq := q.WithTx(tx)

	// The seed lands inside the SAME transaction as the audit row, so the
	// FR-HIS-1 "create" entry records the seeded values as the created
	// baseline — one round trip, correct history, and no spurious "update".
	u, err := txq.UpsertUserOnFirstSeen(ctx, seedParamsFromClaims(pgtype.UUID{Bytes: uuid.New(), Valid: true}, claims))
	if err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "profile: upsert user on first seen failed", "error", err)
		return sqlcgen.IdentityUser{}, err
	}
	if err := writeProfileAuditLog(ctx, txq, u.ID, u.ID, history.ChangeCreate, sqlcgen.IdentityUser{}, u); err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "profile: write profile create audit log failed", "error", err)
		return sqlcgen.IdentityUser{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "profile: commit first-seen create transaction failed", "error", err)
		return sqlcgen.IdentityUser{}, err
	}
	return u, nil
}

func getProfile(pool *pgxpool.Pool, q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := authn.FromContext(r.Context())
		if !ok {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: auth claims missing from context")
			problem.Write(w, r, problem.Internal())
			return
		}

		// Existence is checked before the upsert (outside any transaction —
		// a plain read) purely to know whether this call is the first-seen
		// create or an ordinary re-GET of an existing profile: the audit log
		// must record exactly one "create" row per profile, never one per
		// GET (UpsertUserOnFirstSeen's ON CONFLICT branch is a semantic
		// no-op read, not a new change).
		//
		// Known limitation, accepted for v1 (no separate GitHub issue — see
		// the rationale below for why this is deliberately left as-is):
		// this check-then-act has a narrow TOCTOU race under two truly
		// concurrent first-ever GETs for the same brand-new oidc_sub (both
		// could see isNew=true and both write a "create" audit row, though
		// oidc_sub's UNIQUE constraint still guarantees only one
		// identity.users row is ever created) — accepted for v1, same risk
		// class as apiaries' own idempotency check-then-act; a literal
		// first-login-racing-itself is rare enough that closing it would
		// need SELECT ... FOR UPDATE-style locking beyond what this seam
		// needs.
		existing, err := q.GetUserByOidcSub(r.Context(), claims.Sub)
		isNew := errors.Is(err, pgx.ErrNoRows)
		if err != nil && !isNew {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: get user by oidc sub failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}

		if !isNew {
			// Ordinary re-GET of an existing profile: no domain change, so
			// no audit row (mirrors apiaries' "idempotent replay writes no
			// new audit row", history.md §4). The row read above is served
			// directly — the upsert that used to run here was a semantic
			// no-op re-read, and removing it also removes the one call site
			// a reader could mistake for a re-sync of the seeded values.
			writeJSON(w, http.StatusOK, toProfileResponse(existing, claims))
			return
		}

		u, err := createProfileOnFirstSeen(r.Context(), pool, q, claims)
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, http.StatusOK, toProfileResponse(u, claims))
	}
}

// parseProfileUpdateRequest validates a decoded PATCH /v1/profile body and
// builds the sqlcgen params for UpdateUserProfile, or the field errors to
// report back (problem.ValidationFailed) if any field is invalid. It is pure
// (no ctx/DB), extracted out of updateProfile (code-review HIGH #3) so the
// validation rules are unit-testable on their own. The caller is responsible
// for stamping OidcSub onto the returned params.
func parseProfileUpdateRequest(body profileUpdateRequest) (sqlcgen.UpdateUserProfileParams, []problem.FieldError) {
	var fieldErrs []problem.FieldError
	var params sqlcgen.UpdateUserProfileParams

	if body.Name != nil {
		name := strings.TrimSpace(*body.Name)
		switch {
		case name == "":
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
		case utf8.RuneCountInString(name) > maxNameLength:
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
		default:
			params.SetName = true
			params.Name = name
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

	return params, fieldErrs
}

func updateProfile(pool *pgxpool.Pool, q *sqlcgen.Queries) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := authn.FromContext(r.Context())
		if !ok {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: auth claims missing from context")
			problem.Write(w, r, problem.Internal())
			return
		}

		var body profileUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		// Ordering is load-bearing: a body of ONLY {"email": ...} must be
		// told the field is read-only, not that it sent no fields. Refused
		// rather than ignored so a client can never believe it saved an
		// address it did not (#365 follow-up, D-7).
		if body.Email != nil {
			problem.Write(w, r, problem.ValidationFailed(
				"email is managed by the identity provider and cannot be set here",
				problem.FieldError{
					Field:   "email",
					Code:    "read_only",
					Message: "email is read-only; change it at your account provider",
				}))
			return
		}

		if body.Name == nil && body.Locale == nil {
			problem.Write(w, r, problem.ValidationFailed("at least one field is required"))
			return
		}

		params, fieldErrs := parseProfileUpdateRequest(body)
		params.OidcSub = claims.Sub
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// The row is normally guaranteed to exist by the time a client can
		// PATCH (onboarding always does a GET, which get-or-creates it,
		// first) — but UPDATE ... RETURNING matching zero rows is still
		// handled explicitly (pgx.ErrNoRows) rather than folded into the
		// generic 500 branch, since "no such profile yet" is a legitimate,
		// distinguishable case, not a server fault. The before-state read,
		// the update, and its identity.audit_log row all run in the same
		// local transaction (history.md §4, #165).
		tx, err := pool.Begin(r.Context())
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: begin update transaction failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}
		defer tx.Rollback(r.Context()) //nolint:errcheck // no-op after a successful Commit
		txq := q.WithTx(tx)

		before, err := txq.GetUserByOidcSub(r.Context(), claims.Sub)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("no profile exists yet for the caller — GET /v1/profile first"))
			return
		}
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: get user by oidc sub failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}

		u, err := txq.UpdateUserProfile(r.Context(), params)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("no profile exists yet for the caller — GET /v1/profile first"))
			return
		}
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: update user profile failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}
		if err := writeProfileAuditLog(r.Context(), txq, u.ID, u.ID, history.ChangeUpdate, before, u); err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: write profile update audit log failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "profile: commit update transaction failed", "error", err)
			problem.Write(w, r, problem.Internal())
			return
		}

		writeJSON(w, http.StatusOK, toProfileResponse(u, claims))
	}
}

// toProfileResponse renders a row for the client. The address and its
// verification state come from CLAIMS, not from the row: the provider owns
// them (D-7) and u.Email is only the cache seeded at first sight, which a
// later change at the provider leaves stale.
//
// ProfileComplete is the NAME ALONE (#365 follow-up). It used to require an
// email too, which is no longer something onboarding can complete — the
// address arrives with the token or not at all.
func toProfileResponse(u sqlcgen.IdentityUser, claims authn.Claims) ProfileResponse {
	return ProfileResponse{
		ID:              uuid.UUID(u.ID.Bytes).String(),
		Name:            u.Name,
		Email:           claims.Email,
		EmailVerified:   claims.EmailVerified,
		Locale:          u.Locale,
		ProfileComplete: u.Name != "",
		CreatedAt:       u.CreatedAt.Time,
		UpdatedAt:       u.UpdatedAt.Time,
	}
}
