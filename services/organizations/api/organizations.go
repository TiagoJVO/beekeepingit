// Package api (this file) — client-facing organization routes (FR-ONB-2,
// FR-TEN-2, NFR-ROL-1, #26). All three routes run behind authn.NewMiddleware
// only (no authn.NewOrgResolver): that middleware calls out to identity AND
// back into this same service's own /internal/memberships/active over HTTP,
// which would be a needless self-loopback here — organizations already owns
// the memberships table it would be asking itself about. Instead every
// handler resolves org context with resolveActiveMembership below: one
// internal call to identity (sub → user_id, auth.md §5.1 step 1) plus a
// direct DB lookup of the caller's own active membership (step 3) — the same
// two facts NewOrgResolver would produce, minus the redundant HTTP hop.
//
// This also means a brand-new caller (no identity.users row yet, or no active
// membership) is never blanket-403'd by shared middleware before reaching a
// handler: POST /organizations *must* run for exactly that caller (the whole
// point of onboarding), and GET /organizations/me's "no active membership"
// case must come back as a normal, handler-level 404 the client's
// org-completion gate can distinguish from any other failure (mirrors
// profile's GET-as-completeness-probe pattern, client-side).
//
// History recording (FR-HIS-1) for organization create/update is explicitly
// deferred — EPIC-07's audit log isn't built yet. Tracked in
// https://github.com/TiagoJVO/beekeepingit/issues/165; this is the seam where
// an audit write would go once that lands (same deferral as #25's profile).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const maxOrgNameLength = 200

// OrganizationResponse is the client-facing organization shape
// (contracts/openapi/organizations.openapi.yaml's Organization schema).
type OrganizationResponse struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Address   string    `json:"address"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// organizationCreateRequest is the POST /organizations request body
// (OrganizationCreate schema). id is client-generated, so the client can
// address the resource immediately without waiting on the response (matches
// the apiaries client-generated-id convention; contracts/openapi only
// requires `format: uuid`, not a specific version).
type organizationCreateRequest struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address"`
}

// UserResolver maps a verified OIDC subject to its identity.users user_id —
// the one internal call CreateOrganization needs before it can own a row
// (auth.md §5.1 step 1). A small local interface (rather than importing
// authn's private resolver) so it's trivially fakeable in tests.
type UserResolver interface {
	ResolveUserID(ctx context.Context, bearer, sub string) (string, error)
}

// HTTPUserResolver calls identity's internal resolve endpoint directly —
// mirrors authn.NewOrgResolver's own resolveUser step, but this route runs
// before any membership can exist, so it can't sit behind that middleware.
type HTTPUserResolver struct {
	IdentityBaseURL string
	Client          *http.Client
}

// NewHTTPUserResolver builds a resolver with a 5s-timeout, OTel-instrumented
// client (matching authn.NewOrgResolver's default), or a custom Client if
// tests need to fake the transport.
func NewHTTPUserResolver(identityBaseURL string, client *http.Client) *HTTPUserResolver {
	if client == nil {
		client = &http.Client{
			Timeout:   5 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		}
	}
	return &HTTPUserResolver{IdentityBaseURL: identityBaseURL, Client: client}
}

func (h *HTTPUserResolver) ResolveUserID(ctx context.Context, bearer, sub string) (string, error) {
	url := h.IdentityBaseURL + "/internal/users/by-sub/" + sub
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := h.Client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("api: resolve user by sub: identity responded %d", resp.StatusCode)
	}
	var out struct {
		UserID string `json:"user_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	return out.UserID, nil
}

// PublicRouter returns the client-facing /v1 organization routes backed by
// pool, mounted under "/v1" behind authn.NewMiddleware only (see package doc
// for why no authn.NewOrgResolver sits in front of any of these routes).
func PublicRouter(pool *pgxpool.Pool, resolver UserResolver) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Post("/organizations", createOrganization(pool, q, resolver))
	r.Get("/organizations/me", getMyOrganization(q, resolver))
	r.Get("/organizations/{orgId}", getOrganization(q, resolver))
	return r
}

// resolveActiveMembership maps the request's verified sub to its active
// membership: identity (sub → user_id) then a direct DB lookup of
// organizations.memberships (auth.md §5.1 steps 1 and 3), without going
// through the shared authn.NewOrgResolver's HTTP call back into this same
// service (package doc). Returns ok=false with the appropriate problem
// already written — "not a known user" and "no active membership" both
// surface as 404 here (not 403): unlike a resource lookup, there is no
// caller-supplied id to withhold the existence of, and the client's
// org-completion gate needs a clean, distinguishable "you have no org yet"
// signal (mirrors profile's lazy-GET pattern) rather than a blanket 403.
func resolveActiveMembership(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (orgID pgtype.UUID, ok bool) {
	claims, found := authn.FromContext(r.Context())
	if !found {
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, false
	}

	userIDStr, err := resolver.ResolveUserID(r.Context(), r.Header.Get("Authorization"), claims.Sub)
	if err != nil {
		problem.Write(w, r, problem.NotFound("no organization found for the caller"))
		return pgtype.UUID{}, false
	}
	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, false
	}

	m, err := q.GetActiveMembershipByUser(r.Context(), pgtype.UUID{Bytes: userID, Valid: true})
	if errors.Is(err, pgx.ErrNoRows) {
		problem.Write(w, r, problem.NotFound("no organization found for the caller"))
		return pgtype.UUID{}, false
	}
	if err != nil {
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, false
	}
	return m.OrganizationID, true
}

func createOrganization(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := authn.FromContext(r.Context())
		if !ok {
			problem.Write(w, r, problem.Internal())
			return
		}

		var body organizationCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		var fieldErrs []problem.FieldError
		orgID, err := uuid.Parse(body.ID)
		if err != nil {
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "id", Code: "invalid", Message: "id must be a UUID"})
		}
		name := strings.TrimSpace(body.Name)
		switch {
		case name == "":
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
		case len(name) > maxOrgNameLength:
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
		}
		address := strings.TrimSpace(body.Address)
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// Resolve the caller's user_id (auth.md §5.1 step 1). A verified token
		// with no known identity.users row is authenticated but not a
		// recognized user — 403, matching NewOrgResolver's own semantics for
		// the same failure mode.
		userIDStr, err := resolver.ResolveUserID(r.Context(), r.Header.Get("Authorization"), claims.Sub)
		if err != nil {
			problem.Write(w, r, problem.Forbidden("caller is not a known user"))
			return
		}
		userID, err := uuid.Parse(userIDStr)
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		// D-3: the org and the creator's admin membership are created in the
		// same transaction so neither is ever observable without the other.
		tx, err := pool.Begin(r.Context())
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		defer tx.Rollback(r.Context()) //nolint:errcheck // no-op after a successful Commit

		txq := q.WithTx(tx)
		org, err := txq.CreateOrganization(r.Context(), sqlcgen.CreateOrganizationParams{
			ID:        pgtype.UUID{Bytes: orgID, Valid: true},
			Name:      name,
			Address:   address,
			CreatedBy: pgtype.UUID{Bytes: userID, Valid: true},
		})
		if isUniqueViolation(err) {
			problem.Write(w, r, problem.Conflict("an organization with this id already exists"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		if _, err := txq.CreateMembership(r.Context(), sqlcgen.CreateMembershipParams{
			ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
			OrganizationID: org.ID,
			UserID:         pgtype.UUID{Bytes: userID, Valid: true},
		}); err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		if err := tx.Commit(r.Context()); err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		w.Header().Set("Location", "/v1/organizations/"+uuidString(org.ID))
		writeJSON(w, http.StatusCreated, toOrganizationResponse(org))
	}
}

// getMyOrganization resolves the caller's own active membership, then returns
// that organization. The client's org-completion gate (mirrors
// profileProvider) calls this to learn "do I have an org" without needing to
// know its id up front — a 404 here means "none yet", the exact signal the
// router's org-completion redirect gates on.
func getMyOrganization(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, ok := resolveActiveMembership(w, r, q, resolver)
		if !ok {
			return
		}
		row, err := q.GetOrganization(r.Context(), org)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		writeJSON(w, http.StatusOK, toOrganizationResponse(row))
	}
}

// getOrganization requires {orgId} to match the caller's own resolved org
// (ADR-0002, api-contracts.md §9): the path never widens scope, so a
// different (even valid) org id is a 404, not a 403 — the API never confirms
// another org's existence.
func getOrganization(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		org, ok := resolveActiveMembership(w, r, q, resolver)
		if !ok {
			return
		}
		requested, err := uuid.Parse(chi.URLParam(r, "orgId"))
		if err != nil || requested != uuid.UUID(org.Bytes) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return
		}

		row, err := q.GetOrganization(r.Context(), org)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		writeJSON(w, http.StatusOK, toOrganizationResponse(row))
	}
}

// writeJSON and uuidString are defined once in common.go and shared with
// memberships.go.

func toOrganizationResponse(o sqlcgen.OrganizationsOrganization) OrganizationResponse {
	var createdBy string
	if o.CreatedBy.Valid {
		createdBy = uuidString(o.CreatedBy)
	}
	return OrganizationResponse{
		ID:        uuidString(o.ID),
		Name:      o.Name,
		Address:   o.Address,
		CreatedBy: createdBy,
		CreatedAt: o.CreatedAt.Time,
		UpdatedAt: o.UpdatedAt.Time,
	}
}

// isUniqueViolation reports whether err is a Postgres unique_violation
// (SQLSTATE 23505) — the client-generated id already exists.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
