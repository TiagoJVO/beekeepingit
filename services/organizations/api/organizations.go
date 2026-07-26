// Package api (this file) -- client-facing organization routes (FR-ONB-2,
// FR-TEN-2, NFR-ROL-1, #26; member/invitation routes for #27 live in
// invitations.go). All routes run behind authn.NewMiddleware only (no
// authn.NewOrgResolver): that middleware calls out to identity AND back into
// this same service's own /internal/memberships/active over HTTP, which
// would be a needless self-loopback here -- organizations already owns the
// memberships table it would be asking itself about. Instead every handler
// resolves org context with resolveActiveMembership/resolveCaller below: one
// internal call to identity (sub -> user_id + email, auth.md section 5.1 step 1)
// plus a direct DB lookup of the caller's own active membership (step 3) --
// the same facts NewOrgResolver would produce, minus the redundant HTTP hop.
//
// This also means a brand-new caller (no identity.users row yet, or no active
// membership) is never blanket-403'd by shared middleware before reaching a
// handler: POST /organizations *must* run for exactly that caller (the whole
// point of onboarding), and GET /organizations/me's "no active membership"
// case must come back as a normal, handler-level 404 the client's
// org-completion gate can distinguish from any other failure (mirrors
// profile's GET-as-completeness-probe pattern, client-side) -- after first
// trying the accept-on-login fallback in getMyOrganization (#27, FR-ONB-3).
// That fallback matches a pending invitation against the caller's verified
// JWT claims.Email, never identity's resolve-response Email (the mutable
// PATCH /v1/profile field, #25) -- see ResolvedUser's and
// getMyOrganization's doc comments for why that distinction is
// security-critical, not stylistic.
//
// POST /organizations additionally rejects a caller who already has an
// active membership (409) -- the client router gate keeps the normal UI path
// away from a second create, but a direct API call must not be allowed to
// give one user two active memberships, which would break the
// single-org-per-user invariant (C-1) this whole file -- and invitations.go's
// acceptance path -- assumes. That pre-check runs in its own read, separate
// from the create transaction, so it is a best-effort fast path only, not
// the enforcement mechanism: two concurrent create-org (or create-org racing
// an invitation accept) calls for the same user could both pass it before
// either commits (TOCTOU). The actual invariant is enforced by
// idx_memberships_one_active_per_user (migration 00004), a unique partial
// index on memberships(user_id) WHERE status = 'active'; createOrganization
// maps the resulting 23505 unique_violation to the same 409 the pre-check
// returns (see isUniqueViolation's call site below).
//
// History recording (FR-HIS-1, #165): createOrganization writes both the
// organization's and the creator's admin membership's audit_log rows in the
// same D-3 transaction as their domain inserts (history.md section 4); see audit.go
// for the shared writeAuditLog helper and invitations.go for the
// invite/accept/revoke wiring.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

const (
	maxOrgNameLength = 200
	// maxOrgAddressLength bounds the free-text address field -- no cap
	// existed before (MEDIUM review finding); 500 comfortably covers a
	// full postal address (street, locality, region, postal code, country)
	// with room for PT diacritics, matching name's rune-count semantics.
	maxOrgAddressLength = 500
)

// OrganizationResponse is the client-facing organization shape
// (contracts/openapi/organizations.openapi.yaml's Organization schema). Role
// is the caller's own membership role in this org (admin/user, #27's Role
// enum) -- added for #172, so the client can decide whether to show
// admin-only navigation (e.g. the members/invitations screen) without a
// separate request. It is always the resolved caller's role, never a
// property of the organization itself (two callers viewing the same org see
// their own, possibly different, role here).
type OrganizationResponse struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Address   string    `json:"address"`
	CreatedBy string    `json:"created_by"`
	Role      string    `json:"role"`
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
// identity.users.email -- the profile field PATCH /v1/profile (#25) lets the
// caller set to an arbitrary string with no tie back to the IdP-verified
// identity -- so it MUST NOT be used to decide access (e.g. which invitation
// to auto-accept): doing so would let a caller self-edit their profile email
// to someone else's pending invitation and join that org at the invited role.
// Use the
// JWT's verified claims.Email (via resolveCaller's verifiedCaller) for
// anything security-sensitive instead. Kept here only because it's part of
// identity's resolve response and may be useful for non-security display
// purposes later.
type ResolvedUser struct {
	UserID string
	Email  string
}

// UserResolver maps a verified OIDC subject to its identity.users row -- the
// one internal call CreateOrganization needs before it can own a row
// (auth.md section 5.1 step 1), and the one resolveActiveMembership needs for the
// accept-on-login email match. A small local interface (rather than
// importing authn's private resolver) so it's trivially fakeable in tests.
type UserResolver interface {
	Resolve(ctx context.Context, bearer, sub string) (ResolvedUser, error)
	// ResolveNames maps a batch of app user_ids to their display names via
	// identity's internal batch endpoint -- the composition step behind the
	// member-names endpoint (#44 follow-up): organizations knows which
	// user_ids are in the caller's org and that the caller may see them,
	// identity owns the names. Returns a user_id -> name map; ids identity
	// has no row for are simply absent (a removed/never-provisioned member,
	// which the client renders as a short id fragment). Never returns email
	// (FR-TEN-2).
	ResolveNames(ctx context.Context, bearer string, userIDs []string) (map[string]string, error)
}

// HTTPUserResolver calls identity's internal resolve endpoint directly --
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

// ErrUnknownUser is returned by Resolve when identity has no identity.users
// row for the given verified subject -- the ordinary "caller isn't
// provisioned yet" business case (a 403/404 to the client), distinct from a
// resolver transport/5xx failure (an infra fault, HIGH #1 review finding):
// callers must not treat the two identically, since one is an authz outcome
// and the other means identity itself is unreachable or erroring.
var ErrUnknownUser = errors.New("api: identity has no user for the resolved subject")

// Resolve maps a verified OIDC subject to its identity.users row via
// identity's internal GET /internal/users/by-sub/{sub} (auth.md section 5.1 step
// 1), the one internal call this route needs before it can own anything --
// see the package doc for why this can't sit behind authn.NewOrgResolver.
// Returns ErrUnknownUser (not a generic error) when identity reports 404, so
// callers can distinguish "no such user" from a transport/5xx failure
// talking to identity.
func (h *HTTPUserResolver) Resolve(ctx context.Context, bearer, sub string) (ResolvedUser, error) {
	// url.PathEscape (not raw concatenation) matches authn.NewOrgResolver's
	// own resolveUser step: sub is a verified JWT claim, not free-form
	// user input, and escaping it is a correctness fix regardless (a sub
	// could contain URL-meaningful characters).
	reqURL := h.IdentityBaseURL + "/internal/users/by-sub/" + url.PathEscape(sub)
	status, body, err := h.getJSON(ctx, reqURL, bearer)
	if err != nil {
		return ResolvedUser{}, fmt.Errorf("resolve user by sub: call identity: %w", err)
	}
	if status == http.StatusNotFound {
		return ResolvedUser{}, ErrUnknownUser
	}
	if status != http.StatusOK {
		return ResolvedUser{}, fmt.Errorf("resolve user by sub: identity responded %d", status)
	}
	var out struct {
		UserID string `json:"user_id"`
		Email  string `json:"email"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return ResolvedUser{}, fmt.Errorf("resolve user by sub: decode identity response: %w", err)
	}
	return ResolvedUser{UserID: out.UserID, Email: out.Email}, nil
}

// ResolveNames maps a batch of app user_ids to display names via identity's
// internal GET /internal/users/names?ids=... -- the composition step behind
// GET /organizations/{orgId}/members/names (#44 follow-up). Forwards the
// caller's bearer exactly like Resolve (that endpoint sits behind the same
// OIDC authn middleware). An empty input is a no-op (no HTTP call). Any
// non-200, transport error, or malformed body is returned as an error so the
// handler can surface a 502 rather than silently showing every member as a
// short id.
func (h *HTTPUserResolver) ResolveNames(ctx context.Context, bearer string, userIDs []string) (map[string]string, error) {
	names := make(map[string]string, len(userIDs))
	if len(userIDs) == 0 {
		return names, nil
	}
	// ids is a comma-separated list; url.QueryEscape keeps the commas intact
	// as a single value (the ids are UUIDs from our own membership rows, not
	// free-form input).
	reqURL := h.IdentityBaseURL + "/internal/users/names?ids=" + url.QueryEscape(strings.Join(userIDs, ","))
	status, body, err := h.getJSON(ctx, reqURL, bearer)
	if err != nil {
		return nil, fmt.Errorf("resolve user names: call identity: %w", err)
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("resolve user names: identity responded %d", status)
	}
	var out struct {
		Data []struct {
			UserID string `json:"user_id"`
			Name   string `json:"name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("resolve user names: decode identity response: %w", err)
	}
	for _, u := range out.Data {
		names[u.UserID] = u.Name
	}
	return names, nil
}

// getJSON issues an authenticated GET against rawURL -- an internal,
// operator-controlled service base URL (from config, never a client
// request field) plus a URL-escaped path segment, the same trust boundary
// authn.NewOrgResolver's own internal calls cross. Factored out to its own
// function (mirroring that resolver's getJSON) rather than inlined in
// Resolve.
func (h *HTTPUserResolver) getJSON(ctx context.Context, rawURL, bearer string) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil) //nolint:gosec // G704: rawURL is built from an operator-configured internal base URL (INTERNAL_IDENTITY_URL) + a url.PathEscape'd JWT sub, not a client-supplied request field -- see doc above.
	if err != nil {
		return 0, nil, fmt.Errorf("build identity request: %w", err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := h.Client.Do(req) //nolint:gosec // G704: same internal-base-URL + escaped-path-segment reqURL as above, not a client-supplied request field.
	if err != nil {
		return 0, nil, fmt.Errorf("call identity: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, fmt.Errorf("read identity response body: %w", err)
	}
	return resp.StatusCode, body, nil
}

// identityUnavailable builds a 502 problem for a resolver transport/5xx
// failure talking to identity -- distinct from ErrUnknownUser's ordinary
// 403/404 (HIGH #1 review finding: the two must not look identical to the
// client, and this path must be logged, since it means an upstream
// dependency is failing, not that the caller is unauthorized). The shared
// problem package has no 502 constructor (matches services/sync/api/
// coordinator.go's own badGateway, which notes the same gap) -- built
// directly here rather than adding a single-caller constructor there.
func identityUnavailable(detail string) problem.Problem {
	return problem.Problem{
		Title:  "Bad Gateway",
		Status: http.StatusBadGateway,
		Detail: detail,
		Code:   "organizations.identity_unavailable",
	}
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
	r.Patch("/organizations/{orgId}", updateOrganization(pool, q, resolver))
	registerMemberAndInvitationRoutes(r, pool, q, resolver)
	return r
}

// callerMembership is the resolved (org, user, role) tuple resolveActiveMembership
// produces for the caller of the current request.
//
// #466: this is now a UNION of two distinct shapes, discriminated by
// AuthorizedVia -- not a single invariant struct anymore. When AuthorizedVia
// is "" (the ordinary membership path -- resolveActiveMembership,
// requireOrgMember/requireOrgAdmin, entirely unchanged by #466), UserID is
// genuinely an ACTIVE MEMBER of OrgID with role Role, backed by a real
// organizations.memberships row, and every invariant that implies (e.g.
// GetOrganizationForUpdate's "OrgID is guaranteed to exist" assumption,
// organizations.go) holds. When AuthorizedVia is authorizedViaPlatformOperator
// (platform_authz.go), UserID is the verified platform operator's OWN
// identity -- NOT a member of OrgID at all, no memberships row backs this
// callerMembership -- and Role is a fixed sentinel (platformOperatorRole),
// not a real membership role read from the database. Do not assume a
// callerMembership implies DB-backed membership without checking
// AuthorizedVia first; see platform_authz.go's package doc for the full
// contract.
type callerMembership struct {
	OrgID  pgtype.UUID
	UserID pgtype.UUID
	Role   string
	// AuthorizedVia records which of the two authorization paths (#466)
	// produced this callerMembership: the zero value "" is the ordinary
	// membership-derived path (requireOrgMember/requireOrgAdmin,
	// resolveActiveMembership -- entirely unchanged by #466, so every
	// pre-existing call site simply never sets this field, and Go's zero
	// value for a new struct field requires no change to those call sites)
	// or authorizedViaPlatformOperator (platform_authz.go) for the verified-
	// claim carve-out. Never serialized to any client response --
	// recoverability for #470's audit-attribution story and for this
	// package's own structured logging (platform_authz.go logs every grant
	// through that path regardless of this field).
	AuthorizedVia string
}

// resolveActiveMembership maps the request's verified sub to its active
// membership: identity (sub -> user_id) then a direct DB lookup of
// organizations.memberships (auth.md section 5.1 steps 1 and 3), without going
// through the shared authn.NewOrgResolver's HTTP call back into this same
// service (package doc). Returns ok=false with the appropriate problem
// already written -- "not a known user" and "no active membership" both
// surface as 404 here (not 403): unlike a resource lookup, there is no
// caller-supplied id to withhold the existence of, and the client's
// org-completion gate needs a clean, distinguishable "you have no org yet"
// signal (mirrors profile's lazy-GET pattern) rather than a blanket 403.
func resolveActiveMembership(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	_, userID, ok := resolveCaller(w, r, resolver)
	if !ok {
		return callerMembership{}, false
	}
	member, err := activeMembershipFor(r.Context(), q, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		problem.Write(w, r, problem.NotFound("no organization found for the caller"))
		return callerMembership{}, false
	}
	if err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "resolve active membership failed", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return callerMembership{}, false
	}
	return member, true
}

// activeMembershipFor looks up userID's active membership, returning
// pgx.ErrNoRows as-is (no response written) rather than a wrapped Problem --
// unlike resolveActiveMembership, getMyOrganization needs to try the
// accept-on-login fallback before deciding this is a genuine 404, so it
// can't have a response already committed to the ResponseWriter at this
// point. Takes ctx directly (not *http.Request) since it does no
// request-specific work beyond the context.
func activeMembershipFor(ctx context.Context, q *sqlcgen.Queries, userID pgtype.UUID) (callerMembership, error) {
	m, err := q.GetActiveMembershipByUser(ctx, userID)
	if err != nil {
		return callerMembership{}, err
	}
	return callerMembership{OrgID: m.OrganizationID, UserID: userID, Role: m.Role}, nil
}

// verifiedCaller carries the token-verified identity facts resolveCaller
// hands back, alongside the DB-resolved userID: VerifiedEmail/EmailVerified
// come straight from the JWT claims (auth.md section 3.4), never from identity's
// resolve response, which reflects the mutable identity.users.email profile
// field a caller can PATCH to any string via PATCH /v1/profile (#25). Using
// the profile email for anything security-sensitive -- like matching a
// pending invitation -- would let a caller claim any org's invitation just by
// setting their profile email to match it. See acceptPendingInvitationByEmail.
type verifiedCaller struct {
	ResolvedUser
	VerifiedEmail string
	EmailVerified bool
}

// resolveCaller resolves the request's verified sub to its identity.users
// row (auth.md section 5.1 step 1) -- the shared first step behind
// resolveActiveMembership and acceptPendingInvitationByEmail. Writes the
// appropriate problem and returns ok=false on any failure; callers must stop
// on !ok exactly like resolveActiveMembership's other callers do.
//
// A resolver failure is split two ways (HIGH #1 review finding):
// ErrUnknownUser (identity has no row for this subject) is the ordinary,
// unlogged "no organization found for the caller" 404 business case; any
// other error means identity itself is unreachable or erroring, which is
// logged and surfaced as 502 rather than silently looking like "unknown
// user".
func resolveCaller(w http.ResponseWriter, r *http.Request, resolver UserResolver) (verifiedCaller, pgtype.UUID, bool) {
	claims, found := authn.FromContext(r.Context())
	if !found {
		problem.Write(w, r, problem.Internal())
		return verifiedCaller{}, pgtype.UUID{}, false
	}

	resolved, err := resolver.Resolve(r.Context(), r.Header.Get("Authorization"), claims.Sub)
	if err != nil {
		if errors.Is(err, ErrUnknownUser) {
			problem.Write(w, r, problem.NotFound("no organization found for the caller"))
			return verifiedCaller{}, pgtype.UUID{}, false
		}
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "resolve caller failed", slog.Any("error", err))
		problem.Write(w, r, identityUnavailable("identity service is unavailable"))
		return verifiedCaller{}, pgtype.UUID{}, false
	}
	userID, err := uuid.Parse(resolved.UserID)
	if err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse resolved user id failed", slog.Any("error", err))
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
		case utf8.RuneCountInString(name) > maxOrgNameLength:
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
		}
		address := strings.TrimSpace(body.Address)
		if utf8.RuneCountInString(address) > maxOrgAddressLength {
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "address", Code: "too_long", Message: "address must be at most 500 characters"})
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// Resolve the caller's user_id (auth.md section 5.1 step 1). ErrUnknownUser
		// (a verified token with no known identity.users row) is
		// authenticated but not a recognized user -- 403, matching
		// NewOrgResolver's own semantics for the same failure mode. Any other
		// resolver error means identity itself is unreachable/erroring
		// (HIGH #1 review finding) -- logged and surfaced as 502, not
		// silently identical to "not a known user".
		resolved, err := resolver.Resolve(r.Context(), r.Header.Get("Authorization"), claims.Sub)
		if err != nil {
			if errors.Is(err, ErrUnknownUser) {
				problem.Write(w, r, problem.Forbidden("caller is not a known user"))
				return
			}
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "resolve caller failed", slog.Any("error", err))
			problem.Write(w, r, identityUnavailable("identity service is unavailable"))
			return
		}
		userID, err := uuid.Parse(resolved.UserID)
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "parse resolved user id failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		// Reject a second org for a caller who already has an active
		// membership: the client-side router gate steers the normal UI path
		// away from this (an org-complete user never reaches the creation
		// form), but nothing stops a direct API call otherwise, and a second
		// active membership would violate the single-org-per-user invariant
		// (C-1) the rest of the system -- including #27's own invitation
		// acceptance below -- assumes. pgx.ErrNoRows (no existing membership)
		// is the expected, successful case here, not a failure. This is a
		// best-effort fast path only (TOCTOU window against a concurrent
		// caller) -- the actual invariant is enforced below by
		// idx_memberships_one_active_per_user.
		if _, err := q.GetActiveMembershipByUser(r.Context(), pgtype.UUID{Bytes: userID, Valid: true}); err == nil {
			problem.Write(w, r, problem.Conflict("caller already belongs to an organization"))
			return
		} else if !errors.Is(err, pgx.ErrNoRows) {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "check existing membership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		// D-3: the org and the creator's admin membership are created in the
		// same transaction so neither is ever observable without the other
		// (history.md section 4 gets both their audit rows in the same tx too).
		now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
		actor := pgtype.UUID{Bytes: userID, Valid: true}
		var org sqlcgen.OrganizationsOrganization
		var membership sqlcgen.OrganizationsMembership
		txErr := withTx(r.Context(), pool, func(tx pgx.Tx) error {
			txq := q.WithTx(tx)
			var err error
			org, err = txq.CreateOrganization(r.Context(), sqlcgen.CreateOrganizationParams{
				ID:        pgtype.UUID{Bytes: orgID, Valid: true},
				Name:      name,
				Address:   address,
				CreatedBy: actor,
			})
			if err != nil {
				return fmt.Errorf("create organization: %w", err)
			}

			// History (FR-HIS-1, #165): the org's own create row, in the
			// same D-3 transaction as the domain write. occurred_at is
			// server-now -- org creation has no client-supplied device
			// timestamp the way apiaries' offline sync-apply ops do.
			// actor_scope (#470) is always actorScopeMember here: this route
			// runs before any {orgId} exists to authorize a platform operator
			// against (platform_authz.go's carve-out is keyed on an existing
			// {orgId} path param), so it is never reachable via that path.
			if err := writeAuditLog(r.Context(), txq, org.ID, entityTypeOrganization, org.ID, actor, actorScopeMember, now,
				history.ChangeCreate, nil, organizationFields(org)); err != nil {
				return fmt.Errorf("write organization audit log: %w", err)
			}

			membership, err = txq.CreateMembership(r.Context(), sqlcgen.CreateMembershipParams{
				ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
				OrganizationID: org.ID,
				UserID:         actor,
			})
			if err != nil {
				// CRITICAL (TOCTOU fix): idx_memberships_one_active_per_user
				// (migration 00004) is what actually stops a second
				// concurrent caller getting past the pre-check above -- this
				// insert is where its unique_violation surfaces when that
				// race is lost. Mapped to the same 409 the pre-check
				// returns below, outside the closure (isUniqueViolation
				// unwraps through this %w).
				return fmt.Errorf("create membership: %w", err)
			}

			// The creator's admin membership is a second entity created in
			// this same transaction (D-3) -- its own audit row,
			// entity_type=membership. Same actor_scope reasoning as the
			// organization's own create row above.
			if err := writeAuditLog(r.Context(), txq, org.ID, entityTypeMembership, membership.ID, actor, actorScopeMember, now,
				history.ChangeCreate, nil, membershipFields(membership)); err != nil {
				return fmt.Errorf("write membership audit log: %w", err)
			}
			return nil
		})
		if txErr != nil {
			if isUniqueViolation(txErr) {
				if !org.ID.Valid {
					// The org insert itself lost a unique_violation -- the
					// client-generated id already exists.
					problem.Write(w, r, problem.Conflict("an organization with this id already exists"))
					return
				}
				// The org insert succeeded; the membership insert lost the
				// idx_memberships_one_active_per_user race (CRITICAL fix) --
				// same 409 the pre-check above returns for the sequential
				// case.
				problem.Write(w, r, problem.Conflict("caller already belongs to an organization"))
				return
			}
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "create organization failed", slog.Any("error", txErr))
			problem.Write(w, r, problem.Internal())
			return
		}

		w.Header().Set("Location", "/v1/organizations/"+uuidString(org.ID))
		// ETag is the row's updated_at version stamp (etagFor) -- the contract
		// declares it on this 201, and it's the value a client echoes back in
		// If-Match on a later PATCH (#289 optimistic concurrency, FR-TEN-2).
		w.Header().Set("ETag", etagFor(org.UpdatedAt))
		// The creator is always admin (D-3) -- no extra lookup needed for the
		// role this response reports.
		writeJSON(w, r, http.StatusCreated, toOrganizationResponse(org, "admin"))
	}
}

// getMyOrganization resolves the caller's own active membership, then returns
// that organization. The client's org-completion gate (mirrors
// profileProvider) calls this to learn "do I have an org" without needing to
// know its id up front -- a 404 here means "none yet", the exact signal the
// router's org-completion redirect gates on.
//
// Before giving up with a 404, it checks for a pending invitation matching
// the caller's own email and auto-accepts it (FR-ONB-3 AC: "an invited user
// who logs in is joined to the inviting organization rather than prompted to
// create a new one") -- see acceptPendingInvitationByEmail. This is the only
// place that lookup happens: getOrganization's "does {orgId} match my org"
// question has nothing to do with whether the caller has *any* org, so it
// stays a plain membership check.
//
// Security-critical: the email matched against is the JWT's verified
// claims.Email (via resolveCaller's verifiedCaller), never
// identity.users.email (the mutable PATCH /v1/profile field, #25) -- using
// the latter would let any authenticated caller self-edit their profile
// email to someone else's pending invitation and auto-join that org at the
// invited role (including admin) without ever controlling that address.
// EmailVerified is checked too (auth.md section 3.4: gate sensitive flows on it) --
// an unverified email is treated exactly like "no pending invitation" (falls
// through to the ordinary 404), not a distinguishable error, so the client
// can't probe verification state through this endpoint.
func getMyOrganization(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		caller, userID, ok := resolveCaller(w, r, resolver)
		if !ok {
			return
		}

		member, err := activeMembershipFor(r.Context(), q, userID)
		if errors.Is(err, pgx.ErrNoRows) {
			// No membership yet -- try the accept-on-login fallback (FR-ONB-3
			// AC 2) before deciding this is genuinely "no org" for the caller.
			// An unverified email can't claim any invitation -- treat it the
			// same as "none pending" rather than skipping the lookup with a
			// different error, so verification state isn't observable here.
			email := ""
			if caller.EmailVerified {
				email = caller.VerifiedEmail
			}
			accepted, acceptErr := acceptPendingInvitationByEmail(r.Context(), pool, q, userID, email)
			if acceptErr != nil {
				if errors.Is(acceptErr, pgx.ErrNoRows) {
					problem.Write(w, r, problem.NotFound("no organization found for the caller"))
					return
				}
				logging.FromContext(r.Context()).ErrorContext(r.Context(), "accept pending invitation failed", slog.Any("error", acceptErr))
				problem.Write(w, r, problem.Internal())
				return
			}
			member = accepted
		} else if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "resolve active membership failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		row, err := q.GetOrganization(r.Context(), member.OrgID)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return
		}
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get organization failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		// ETag version stamp so the client can round-trip it back in If-Match
		// on a PATCH (#289, FR-TEN-2) -- same etagFor derivation the PATCH
		// handler compares against.
		w.Header().Set("ETag", etagFor(row.UpdatedAt))
		writeJSON(w, r, http.StatusOK, toOrganizationResponse(row, member.Role))
	}
}

// getOrganization requires {orgId} to match the caller's own resolved org
// (ADR-0002, api-contracts.md section 9): the path never widens scope, so a
// different (even valid) org id is a 404, not a 403 -- the API never confirms
// another org's existence. #466: a verified platform operator is the one
// deliberate exception -- requirePlatformOperatorOrOrgMember grants it
// {orgId} access outside their own membership (ADR-0021); every other caller
// goes through requireOrgMember exactly as before (this is a pure
// call-site-equivalent refactor of the inline resolveActiveMembership +
// {orgId}-match check this handler used to run itself -- byte-for-byte the
// same logic requireOrgMember (invitations.go) already centralizes).
func getOrganization(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requirePlatformOperatorOrOrgMember(w, r, q, resolver)
		if !ok {
			return
		}

		row, err := q.GetOrganization(r.Context(), member.OrgID)
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return
		}
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get organization failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		w.Header().Set("ETag", etagFor(row.UpdatedAt))
		writeJSON(w, r, http.StatusOK, toOrganizationResponse(row, member.Role))
	}
}

// errStaleIfMatch signals, from inside updateOrganization's transaction, that
// the request's If-Match header did not match the org's current version -- the
// closure returns it so the surrounding handler maps it to a 409 (and the tx
// rolls back, leaving the org unchanged) rather than proceeding with the write.
var errStaleIfMatch = errors.New("api: stale If-Match on organization update")

// updateOrganizationRequest is the PATCH /organizations/{orgId} request body
// (OrganizationUpdate schema): name and/or address. Both are pointers so an
// absent key is distinguishable from a supplied one, and presence is tracked
// separately (via the raw field map) so an explicit JSON null on address --
// which the schema's `[string, "null"]` type allows, meaning "clear it" --
// isn't confused with "leave unchanged". name is a non-nullable string
// (schema `type: string`), so a null there is rejected.
type updateOrganizationRequest struct {
	Name    *string `json:"name"`
	Address *string `json:"address"`
}

// updateOrganization applies an admin's edit of their own org's mutable
// fields (PATCH /organizations/{orgId}, #289, FR-ONB-2). It is admin-only and
// org-scoped: requireOrgAdmin asserts {orgId} matches the caller's own
// resolved org (404 otherwise -- ADR-0002, the path never widens scope) and
// that the caller is that org's admin (403 otherwise -- auth.md §5.3,
// NFR-ROL-1). #466: a verified platform operator may also reach this route
// for an org it is not a member of (requirePlatformOperatorOrOrgAdmin,
// ADR-0021); every other caller goes through requireOrgAdmin unchanged.
// Invalid payloads are rejected before any write (422, NFR-SEC-1).
// Optimistic concurrency uses the If-Match / ETag version stamp: a stale value
// is a 409 (FR-TEN-2). The applied change is recorded in organizations.audit_log
// with actor + timestamp, in the same transaction as the domain write
// (FR-HIS-1, #165, history.md §4).
func updateOrganization(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requirePlatformOperatorOrOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}

		// Decode to a raw field map first so key PRESENCE (not just non-nil
		// value) is observable: OrganizationUpdate has minProperties:1, and
		// address distinguishes "absent" (leave unchanged) from explicit null
		// (clear) -- neither of which a plain struct decode alone can tell
		// apart from a zero value.
		var fields map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&fields); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}
		var body updateOrganizationRequest
		if err := json.Unmarshal(rawFieldsToObject(fields), &body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}
		_, nameSet := fields["name"]
		_, addressSet := fields["address"]

		if fieldErrs := validateOrganizationUpdate(body, nameSet, addressSet); len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
		var updated sqlcgen.OrganizationsOrganization
		txErr := withTx(r.Context(), pool, func(tx pgx.Tx) error {
			txq := q.WithTx(tx)
			// Row-locking read (FOR UPDATE) so the If-Match check and the write
			// are atomic against a concurrent PATCH (optimistic concurrency,
			// FR-TEN-2). For the ordinary membership path, member.OrgID is
			// guaranteed to exist -- the caller's active membership references
			// it -- so pgx.ErrNoRows here is a genuine fault, not a business
			// 404. #466: on the platform-operator path there is no membership
			// row backing this guarantee -- member.OrgID's existence was only
			// confirmed by platform_authz.go's own, separate GetOrganization
			// read moments earlier (a TOCTOU window: the org could theoretically
			// be deleted between that check and this one). Still treated as a
			// fault today because no endpoint deletes an organization -- if one
			// is ever added, this call site needs its own pgx.ErrNoRows -> 404
			// handling for the platform path, the same way platform_authz.go's
			// GetOrganization already does.
			current, err := txq.GetOrganizationForUpdate(r.Context(), member.OrgID)
			if err != nil {
				return fmt.Errorf("get organization for update: %w", err)
			}

			if !ifMatchOK(r, etagFor(current.UpdatedAt)) {
				return errStaleIfMatch
			}

			// Compute the desired row from the current one, applying only the
			// fields this PATCH actually carried (matching apiaries' full-row
			// "want" pattern). name is validated non-empty above; address null
			// clears to '' (the column is NOT NULL DEFAULT '').
			wantName := current.Name
			if nameSet {
				wantName = strings.TrimSpace(*body.Name)
			}
			wantAddress := current.Address
			if addressSet {
				if body.Address == nil {
					wantAddress = ""
				} else {
					wantAddress = strings.TrimSpace(*body.Address)
				}
			}

			updated, err = txq.UpdateOrganization(r.Context(), sqlcgen.UpdateOrganizationParams{
				ID:        member.OrgID,
				Name:      wantName,
				Address:   wantAddress,
				UpdatedAt: now,
			})
			if err != nil {
				return fmt.Errorf("update organization: %w", err)
			}

			// History (FR-HIS-1, #165): the org's update row, in the same D-3
			// transaction as the domain write. The actor is the admin making
			// the change; occurred_at is server-now (an admin-app edit has no
			// offline device timestamp). actor_scope (#470) is derived from
			// member.AuthorizedVia -- actorScopePlatformOperator when this
			// write was granted via the verified platform-operator carve-out
			// (requirePlatformOperatorOrOrgAdmin above), actorScopeMember for
			// the org's own admin -- recorded atomically in this same
			// transaction, not inferred later.
			if err := writeAuditLog(r.Context(), txq, member.OrgID, entityTypeOrganization, member.OrgID, member.UserID, actorScopeFor(member.AuthorizedVia), now,
				history.ChangeUpdate, organizationFields(current), organizationFields(updated)); err != nil {
				return fmt.Errorf("write organization audit log: %w", err)
			}
			return nil
		})
		if errors.Is(txErr, errStaleIfMatch) {
			problem.Write(w, r, problem.Conflict("If-Match does not match the current version"))
			return
		}
		if txErr != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "update organization failed", slog.Any("error", txErr))
			problem.Write(w, r, problem.Internal())
			return
		}

		w.Header().Set("ETag", etagFor(updated.UpdatedAt))
		writeJSON(w, r, http.StatusOK, toOrganizationResponse(updated, member.Role))
	}
}

// validateOrganizationUpdate enforces the OrganizationUpdate schema server-side
// (NFR-SEC-1): at least one field present (minProperties:1); name, when
// present, a non-null non-empty string of at most maxOrgNameLength runes;
// address, when present, either null (clear) or at most maxOrgAddressLength
// runes. Rune counts (not byte lengths) match createOrganization's own limits
// so PT diacritics aren't penalized.
func validateOrganizationUpdate(body updateOrganizationRequest, nameSet, addressSet bool) []problem.FieldError {
	var fieldErrs []problem.FieldError
	if !nameSet && !addressSet {
		fieldErrs = append(fieldErrs, problem.FieldError{Field: "(body)", Code: "required", Message: "request must change at least one field"})
	}
	if nameSet {
		switch {
		case body.Name == nil || strings.TrimSpace(*body.Name) == "":
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
		case utf8.RuneCountInString(strings.TrimSpace(*body.Name)) > maxOrgNameLength:
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "name", Code: "too_long", Message: "name must be at most 200 characters"})
		}
	}
	if addressSet && body.Address != nil {
		if utf8.RuneCountInString(strings.TrimSpace(*body.Address)) > maxOrgAddressLength {
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "address", Code: "too_long", Message: "address must be at most 500 characters"})
		}
	}
	return fieldErrs
}

// rawFieldsToObject re-marshals an already-decoded top-level field map back to
// a JSON object so it can be unmarshaled into a typed struct -- the small
// two-stage decode (raw map for key presence, struct for typed values) the
// PATCH handler uses, mirroring apiaries' decodeFields. Marshaling a
// map[string]json.RawMessage never fails (the values are already valid JSON),
// so the error is discarded.
func rawFieldsToObject(fields map[string]json.RawMessage) []byte {
	b, _ := json.Marshal(fields)
	return b
}

// etagFor derives a deterministic, opaque ETag from a row's updated_at -- the
// row's version stamp (data-model.md §4.3), so it changes exactly when the
// row's mutable content changes and is stable across reads of the same
// version. Quoted per RFC 9110 §8.8.3. Mirrors apiaries' etagFor so the two
// services present ETags identically.
func etagFor(updatedAt pgtype.Timestamptz) string {
	return fmt.Sprintf("%q", strconv.FormatInt(updatedAt.Time.UnixNano(), 36))
}

// ifMatchOK reports whether the request's If-Match header (if any) matches
// currentETag -- optimistic concurrency for PATCH (IfMatchHeader,
// contracts/openapi/_shared/components.openapi.yaml). An absent header is
// treated as OK (If-Match is optional per the contract); a present header must
// match exactly, or be the wildcard "*". Mirrors apiaries' ifMatchOK.
func ifMatchOK(r *http.Request, currentETag string) bool {
	want := r.Header.Get("If-Match")
	if want == "" || want == "*" {
		return true
	}
	return want == currentETag
}

// writeJSON and uuidString are defined once in common.go and shared with
// memberships.go.

func toOrganizationResponse(o sqlcgen.OrganizationsOrganization, callerRole string) OrganizationResponse {
	var createdBy string
	if o.CreatedBy.Valid {
		createdBy = uuidString(o.CreatedBy)
	}
	return OrganizationResponse{
		ID:        uuidString(o.ID),
		Name:      o.Name,
		Address:   o.Address,
		CreatedBy: createdBy,
		Role:      callerRole,
		CreatedAt: o.CreatedAt.Time,
		UpdatedAt: o.UpdatedAt.Time,
	}
}

// isUniqueViolation reports whether err is a Postgres unique_violation
// (SQLSTATE 23505) -- the client-generated id already exists, or (since
// migration 00004) a concurrent caller lost the one-active-membership-
// per-user race. errors.As unwraps through any %w wrapping, so callers may
// wrap this error further up the stack without breaking the check.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
