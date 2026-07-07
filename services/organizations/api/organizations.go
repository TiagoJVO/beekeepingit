// Package api (this file) — client-facing organization routes (FR-ONB-2,
// FR-TEN-2, NFR-ROL-1, #26; member/invitation routes for #27 live in
// invitations.go). All routes run behind authn.NewMiddleware only (no
// authn.NewOrgResolver): that middleware calls out to identity AND back into
// this same service's own /internal/memberships/active over HTTP, which
// would be a needless self-loopback here — organizations already owns the
// memberships table it would be asking itself about. Instead every handler
// resolves org context with resolveActiveMembership/resolveCaller below: one
// internal call to identity (sub → user_id + email, auth.md §5.1 step 1)
// plus a direct DB lookup of the caller's own active membership (step 3) —
// the same facts NewOrgResolver would produce, minus the redundant HTTP hop.
//
// This also means a brand-new caller (no identity.users row yet, or no active
// membership) is never blanket-403'd by shared middleware before reaching a
// handler: POST /organizations *must* run for exactly that caller (the whole
// point of onboarding), and GET /organizations/me's "no active membership"
// case must come back as a normal, handler-level 404 the client's
// org-completion gate can distinguish from any other failure (mirrors
// profile's GET-as-completeness-probe pattern, client-side) — after first
// trying the accept-on-login fallback in getMyOrganization (#27, FR-ONB-3).
// That fallback matches a pending invitation against the caller's verified
// JWT claims.Email, never identity's resolve-response Email (the mutable
// PATCH /v1/profile field, #25) — see ResolvedUser's and
// getMyOrganization's doc comments for why that distinction is
// security-critical, not stylistic.
//
// POST /organizations additionally rejects a caller who already has an
// active membership (409) — the client router gate keeps the normal UI path
// away from a second create, but a direct API call must not be allowed to
// give one user two active memberships, which would break the
// single-org-per-user invariant (C-1) this whole file — and invitations.go's
// acceptance path — assumes.
//
// History recording (FR-HIS-1) for organization/membership/invitation
// changes is explicitly deferred — EPIC-07's audit log isn't built yet.
// Tracked in https://github.com/TiagoJVO/beekeepingit/issues/165; this is
// the seam where audit writes would go once that lands (same deferral as
// #25's profile and #26's organization create).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
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

// ResolvedUser is what identity's internal resolve endpoint tells us about a
// verified OIDC subject: identity.users' current row. UserID is the only
// field used for anything security-sensitive. Email mirrors
// identity.users.email — the profile field PATCH /v1/profile (#25) lets the
// caller set to an arbitrary string with no tie back to Keycloak — so it
// MUST NOT be used to decide access (e.g. which invitation to auto-accept):
// doing so would let a caller self-edit their profile email to someone
// else's pending invitation and join that org at the invited role. Use the
// JWT's verified claims.Email (via resolveCaller's verifiedCaller) for
// anything security-sensitive instead. Kept here only because it's part of
// identity's resolve response and may be useful for non-security display
// purposes later.
type ResolvedUser struct {
	UserID string
	Email  string
}

// UserResolver maps a verified OIDC subject to its identity.users row — the
// one internal call CreateOrganization needs before it can own a row
// (auth.md §5.1 step 1), and the one resolveActiveMembership needs for the
// accept-on-login email match. A small local interface (rather than
// importing authn's private resolver) so it's trivially fakeable in tests.
type UserResolver interface {
	Resolve(ctx context.Context, bearer, sub string) (ResolvedUser, error)
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

func (h *HTTPUserResolver) Resolve(ctx context.Context, bearer, sub string) (ResolvedUser, error) {
	// url.PathEscape (not raw concatenation) matches authn.NewOrgResolver's
	// own resolveUser step: sub is a verified JWT claim, not free-form
	// user input, and escaping it is a correctness fix regardless (a sub
	// could contain URL-meaningful characters).
	reqURL := h.IdentityBaseURL + "/internal/users/by-sub/" + url.PathEscape(sub)
	status, body, err := h.getJSON(ctx, reqURL, bearer)
	if err != nil {
		return ResolvedUser{}, err
	}
	if status != http.StatusOK {
		return ResolvedUser{}, fmt.Errorf("api: resolve user by sub: identity responded %d", status)
	}
	var out struct {
		UserID string `json:"user_id"`
		Email  string `json:"email"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return ResolvedUser{}, err
	}
	return ResolvedUser{UserID: out.UserID, Email: out.Email}, nil
}

// getJSON issues an authenticated GET against rawURL — an internal,
// operator-controlled service base URL (from config, never a client
// request field) plus a URL-escaped path segment, the same trust boundary
// authn.NewOrgResolver's own internal calls cross. Factored out to its own
// function (mirroring that resolver's getJSON) rather than inlined in
// Resolve.
func (h *HTTPUserResolver) getJSON(ctx context.Context, rawURL, bearer string) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil) //nolint:gosec // G704: rawURL is built from an operator-configured internal base URL (INTERNAL_IDENTITY_URL) + a url.PathEscape'd JWT sub, not a client-supplied request field — see doc above.
	if err != nil {
		return 0, nil, err
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := h.Client.Do(req) //nolint:gosec // G704: same internal-base-URL + escaped-path-segment reqURL as above, not a client-supplied request field.
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}

// PublicRouter returns the client-facing /v1 organization routes backed by
// pool, mounted under "/v1" behind authn.NewMiddleware only (see package doc
// for why no authn.NewOrgResolver sits in front of any of these routes).
// Member/invitation routes are registered in invitations.go's registerMemberAndInvitationRoutes.
func PublicRouter(pool *pgxpool.Pool, resolver UserResolver) http.Handler {
	q := sqlcgen.New(pool)
	r := chi.NewRouter()
	r.Post("/organizations", createOrganization(pool, q, resolver))
	r.Get("/organizations/me", getMyOrganization(pool, q, resolver))
	r.Get("/organizations/{orgId}", getOrganization(q, resolver))
	registerMemberAndInvitationRoutes(r, q, resolver)
	return r
}

// callerMembership is the resolved (org, user, role) tuple resolveActiveMembership
// produces for the caller of the current request.
type callerMembership struct {
	OrgID  pgtype.UUID
	UserID pgtype.UUID
	Role   string
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
func resolveActiveMembership(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	_, userID, ok := resolveCaller(w, r, resolver)
	if !ok {
		return callerMembership{}, false
	}
	member, err := activeMembershipFor(r, q, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		problem.Write(w, r, problem.NotFound("no organization found for the caller"))
		return callerMembership{}, false
	}
	if err != nil {
		problem.Write(w, r, problem.Internal())
		return callerMembership{}, false
	}
	return member, true
}

// activeMembershipFor looks up userID's active membership, returning
// pgx.ErrNoRows as-is (no response written) rather than a wrapped Problem —
// unlike resolveActiveMembership, getMyOrganization needs to try the
// accept-on-login fallback before deciding this is a genuine 404, so it
// can't have a response already committed to the ResponseWriter at this
// point.
func activeMembershipFor(r *http.Request, q *sqlcgen.Queries, userID pgtype.UUID) (callerMembership, error) {
	m, err := q.GetActiveMembershipByUser(r.Context(), userID)
	if err != nil {
		return callerMembership{}, err
	}
	return callerMembership{OrgID: m.OrganizationID, UserID: userID, Role: m.Role}, nil
}

// verifiedCaller carries the token-verified identity facts resolveCaller
// hands back, alongside the DB-resolved userID: VerifiedEmail/EmailVerified
// come straight from the JWT claims (auth.md §3.4), never from identity's
// resolve response, which reflects the mutable identity.users.email profile
// field a caller can PATCH to any string via PATCH /v1/profile (#25). Using
// the profile email for anything security-sensitive — like matching a
// pending invitation — would let a caller claim any org's invitation just by
// setting their profile email to match it. See acceptPendingInvitationByEmail.
type verifiedCaller struct {
	ResolvedUser
	VerifiedEmail string
	EmailVerified bool
}

// resolveCaller resolves the request's verified sub to its identity.users
// row (auth.md §5.1 step 1) — the shared first step behind
// resolveActiveMembership and acceptPendingInvitationByEmail. Writes the
// appropriate problem and returns ok=false on any failure; callers must stop
// on !ok exactly like resolveActiveMembership's other callers do.
func resolveCaller(w http.ResponseWriter, r *http.Request, resolver UserResolver) (verifiedCaller, pgtype.UUID, bool) {
	claims, found := authn.FromContext(r.Context())
	if !found {
		problem.Write(w, r, problem.Internal())
		return verifiedCaller{}, pgtype.UUID{}, false
	}

	resolved, err := resolver.Resolve(r.Context(), r.Header.Get("Authorization"), claims.Sub)
	if err != nil {
		problem.Write(w, r, problem.NotFound("no organization found for the caller"))
		return verifiedCaller{}, pgtype.UUID{}, false
	}
	userID, err := uuid.Parse(resolved.UserID)
	if err != nil {
		problem.Write(w, r, problem.Internal())
		return verifiedCaller{}, pgtype.UUID{}, false
	}
	caller := verifiedCaller{
		ResolvedUser:  resolved,
		VerifiedEmail: claims.Email,
		EmailVerified: claims.EmailVerified,
	}
	return caller, pgtype.UUID{Bytes: userID, Valid: true}, true
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
		resolved, err := resolver.Resolve(r.Context(), r.Header.Get("Authorization"), claims.Sub)
		if err != nil {
			problem.Write(w, r, problem.Forbidden("caller is not a known user"))
			return
		}
		userID, err := uuid.Parse(resolved.UserID)
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		// Reject a second org for a caller who already has an active
		// membership: the client-side router gate steers the normal UI path
		// away from this (an org-complete user never reaches the creation
		// form), but nothing stops a direct API call otherwise, and a second
		// active membership would violate the single-org-per-user invariant
		// (C-1) the rest of the system — including #27's own invitation
		// acceptance below — assumes. pgx.ErrNoRows (no existing membership)
		// is the expected, successful case here, not a failure.
		if _, err := q.GetActiveMembershipByUser(r.Context(), pgtype.UUID{Bytes: userID, Valid: true}); err == nil {
			problem.Write(w, r, problem.Conflict("caller already belongs to an organization"))
			return
		} else if !errors.Is(err, pgx.ErrNoRows) {
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
//
// Before giving up with a 404, it checks for a pending invitation matching
// the caller's own email and auto-accepts it (FR-ONB-3 AC: "an invited user
// who logs in is joined to the inviting organization rather than prompted to
// create a new one") — see acceptPendingInvitationByEmail. This is the only
// place that lookup happens: getOrganization's "does {orgId} match my org"
// question has nothing to do with whether the caller has *any* org, so it
// stays a plain membership check.
//
// Security-critical: the email matched against is the JWT's verified
// claims.Email (via resolveCaller's verifiedCaller), never
// identity.users.email (the mutable PATCH /v1/profile field, #25) — using
// the latter would let any authenticated caller self-edit their profile
// email to someone else's pending invitation and auto-join that org at the
// invited role (including admin) without ever controlling that address.
// EmailVerified is checked too (auth.md §3.4: gate sensitive flows on it) —
// an unverified email is treated exactly like "no pending invitation" (falls
// through to the ordinary 404), not a distinguishable error, so the client
// can't probe verification state through this endpoint.
func getMyOrganization(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		caller, userID, ok := resolveCaller(w, r, resolver)
		if !ok {
			return
		}

		member, err := activeMembershipFor(r, q, userID)
		if errors.Is(err, pgx.ErrNoRows) {
			// No membership yet — try the accept-on-login fallback (FR-ONB-3
			// AC 2) before deciding this is genuinely "no org" for the caller.
			// An unverified email can't claim any invitation — treat it the
			// same as "none pending" rather than skipping the lookup with a
			// different error, so verification state isn't observable here.
			email := ""
			if caller.EmailVerified {
				email = caller.VerifiedEmail
			}
			accepted, acceptErr := acceptPendingInvitationByEmail(r, pool, q, userID, email)
			if acceptErr != nil {
				if errors.Is(acceptErr, pgx.ErrNoRows) {
					problem.Write(w, r, problem.NotFound("no organization found for the caller"))
					return
				}
				problem.Write(w, r, problem.Internal())
				return
			}
			member = accepted
		} else if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		row, err := q.GetOrganization(r.Context(), member.OrgID)
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
		member, ok := resolveActiveMembership(w, r, q, resolver)
		if !ok {
			return
		}
		requested, err := uuid.Parse(chi.URLParam(r, "orgId"))
		if err != nil || requested != uuid.UUID(member.OrgID.Bytes) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return
		}

		row, err := q.GetOrganization(r.Context(), member.OrgID)
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
