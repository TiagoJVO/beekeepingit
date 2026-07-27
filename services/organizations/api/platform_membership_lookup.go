// Package api (this file) -- the platform-operator cross-organization
// membership lookup (#468, FR-TEN-2, NFR-ROL-1, NFR-SEC-1, D-7, EPIC-18
// #463): answers the support question "which organization(s) does this
// person belong to, and with what role?", impossible before this story since
// every other read in this service is scoped to one {orgId}. It queries
// organizations.memberships across EVERY organization for one resolved
// user, keyed by either their email or their user_id.
//
// Authorization (per #466's handoff comment on this issue, platform_authz.go's
// package doc): this is a brand-new endpoint with no existing {orgId}-scoped
// membership check to extend, so it calls isPlatformOperator(r) directly --
// never requirePlatformOperatorOrOrgMember/...OrgAdmin, which assume an
// {orgId} path param and a membership-or-404 fallback that doesn't apply
// here -- and writes problem.Forbidden (403), not problem.NotFound: ADR-0002's
// "never confirm another org's existence" 404 rule has nothing to hide here,
// since there is no {orgId} in this path at all.
//
// Response shape is deliberately minimal (D-7 -- "identity/account data stays
// at the IdP; this service manages memberships and roles only"): organization
// id + name, role, status only, for every membership (active AND removed --
// unlike the org-scoped member list, a support case may care about a person's
// past org relationships too). NEVER the target's email, credentials, tokens,
// or any other IdP account internal. The email->user_id resolution an
// email-keyed lookup needs stays a LOCAL query against identity's own
// already-mirrored profile data (UserResolver.ResolveByEmail,
// organizations.go) -- no new IdP integration.
package api

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// PlatformMembershipResponse is one organization membership in a #468
// cross-organization lookup result (contracts/openapi/organizations.openapi.yaml's
// PlatformMembership schema): organization id + name, role, status only
// (D-7) -- never the target person's email, credentials, or any other IdP
// account internal.
type PlatformMembershipResponse struct {
	OrganizationID   string `json:"organization_id"`
	OrganizationName string `json:"organization_name"`
	Role             string `json:"role"`
	Status           string `json:"status"`
}

// platformMembershipListResponse is the PlatformMembershipList schema.
// UserID is the resolved subject's own id, echoed back so an email-keyed
// caller can confirm which person the results are for; it is null when the
// lookup key (email) matched no known identity at all -- the same "empty
// result, not an error" outcome as a real person with zero memberships, so a
// support operator can't distinguish "never registered" from "registered,
// no orgs" purely from this response (deliberately: neither fact is
// sensitive on its own, and collapsing them keeps the contract simple).
type platformMembershipListResponse struct {
	UserID *string                      `json:"user_id"`
	Data   []PlatformMembershipResponse `json:"data"`
	Page   pageResponse                 `json:"page"`
}

// registerPlatformRoutes mounts #468's platform-operator-only
// cross-organization membership lookup onto the same router organizations.go's
// PublicRouter returns.
func registerPlatformRoutes(r chi.Router, q *sqlcgen.Queries, resolver UserResolver) {
	r.Get("/organizations/platform/memberships", lookupPlatformMembershipsHandler(q, resolver))
}

// lookupPlatformMembershipsHandler is #468's handler. See the package doc for
// the authorization contract and response shape; see parseLookupKey/
// resolveLookupTarget for the email/user_id lookup-key handling.
//
// Validation order deliberately mirrors platformOperatorMembership's own
// (platform_authz.go): every LOCAL check (the platform-operator claim, the
// request's own query-param shape, pagination params) runs to completion
// before either of this handler's two EXTERNAL calls (resolving the
// operator's own identity; resolving an email-keyed target's user_id) --
// so a malformed request (missing/conflicting params, a non-UUID user_id)
// always gets a clean 422 without depending on, or paying the latency of, a
// round trip to identity, and never gets misreported as a 502 if identity
// happens to be unavailable.
func lookupPlatformMembershipsHandler(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !isPlatformOperator(r) {
			problem.Write(w, r, problem.Forbidden("caller is not a platform operator"))
			return
		}

		key, ok := parseLookupKey(w, r)
		if !ok {
			return
		}
		limit, cursor, ok := parsePage(w, r)
		if !ok {
			return
		}

		operatorUserID, ok := resolveOperatorIdentity(w, r, resolver)
		if !ok {
			return
		}

		targetUserID, found, ok := resolveLookupTarget(w, r, resolver, key)
		if !ok {
			return
		}

		if !found {
			// The lookup key (email) resolved to no known identity -- an
			// empty result, not an error (see platformMembershipListResponse's
			// doc comment on why this looks identical to "zero memberships").
			writeJSON(w, r, http.StatusOK, platformMembershipListResponse{Data: []PlatformMembershipResponse{}, Page: pageResponse{Limit: limit}})
			return
		}

		rows, err := q.ListMembershipsByUser(r.Context(), sqlcgen.ListMembershipsByUserParams{
			UserID: targetUserID,
			Limit:  int32(limit + 1), //nolint:gosec // limit is clamped to [1,maxPageLimit=200]
			Cursor: cursor,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list platform memberships failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		page := pageResponse{Limit: limit}
		if len(rows) > limit {
			next := uuidString(rows[limit-1].ID)
			page.NextCursor = &next
			rows = rows[:limit]
		}
		data := make([]PlatformMembershipResponse, 0, len(rows))
		for _, row := range rows {
			data = append(data, PlatformMembershipResponse{
				OrganizationID:   uuidString(row.OrganizationID),
				OrganizationName: row.OrganizationName,
				Role:             row.Role,
				Status:           row.Status,
			})
		}

		targetUserIDStr := uuidString(targetUserID)
		// Every successful lookup is logged at INFO, mirroring
		// platformOperatorMembership's own grant logging (platform_authz.go):
		// this endpoint is unconditionally cross-tenant by design, so the
		// operator's own identity + which target they looked up belongs in
		// the log stream even on success -- the recoverability signal #470's
		// persisted audit-attribution story can build on. Never logs the raw
		// email query key (NFR-SEC-1) -- only the resolved, already-opaque
		// user_id.
		logging.FromContext(r.Context()).InfoContext(r.Context(), "authz granted: platform operator looked up a person's cross-organization memberships",
			slog.String("operator_user_id", operatorUserID),
			slog.String("target_user_id", targetUserIDStr),
			slog.Int("membership_count", len(data)),
			slog.String("path", r.URL.Path),
			slog.String("method", r.Method),
		)
		writeJSON(w, r, http.StatusOK, platformMembershipListResponse{UserID: &targetUserIDStr, Data: data, Page: page})
	}
}

// resolveOperatorIdentity resolves the calling platform operator's OWN
// identity.users row -- the same call platformOperatorMembership makes
// (platform_authz.go), needed here purely for the grant log's
// operator_user_id (this is a read endpoint; there is no audit_log row to
// attribute a write to). Only ever called after isPlatformOperator has
// already returned true.
func resolveOperatorIdentity(w http.ResponseWriter, r *http.Request, resolver UserResolver) (string, bool) {
	claims, ok := authn.FromContext(r.Context())
	if !ok {
		// Programming error: isPlatformOperator already returned true, which
		// requires FromContext to have succeeded moments ago.
		problem.Write(w, r, problem.Internal())
		return "", false
	}
	resolved, err := resolver.Resolve(r.Context(), r.Header.Get("Authorization"), claims.Sub)
	if err != nil {
		if errors.Is(err, ErrUnknownUser) {
			problem.Write(w, r, problem.Forbidden("caller is not a known user"))
			return "", false
		}
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "platform membership lookup: resolve operator identity failed", slog.Any("error", err))
		problem.Write(w, r, identityUnavailable("identity service is unavailable"))
		return "", false
	}
	return resolved.UserID, true
}

// lookupKey is the request's validated (but not yet resolved) `email`/
// `user_id` query parameter -- see parseLookupKey.
type lookupKey struct {
	email    string      // non-empty when keyed by email
	userID   pgtype.UUID // Valid when keyed by user_id
	byUserID bool
}

// parseLookupKey validates the request's `email`/`user_id` query parameters
// (exactly one required, a supplied user_id must be a UUID, a supplied email
// must look like one) -- purely LOCAL checks, no I/O. ok=false means a 422
// has already been written. See lookupPlatformMembershipsHandler's doc
// comment for why this must run before either of this endpoint's external
// calls.
func parseLookupKey(w http.ResponseWriter, r *http.Request) (lookupKey, bool) {
	query := r.URL.Query()
	email := strings.TrimSpace(query.Get("email"))
	rawUserID := strings.TrimSpace(query.Get("user_id"))

	switch {
	case email == "" && rawUserID == "":
		problem.Write(w, r, problem.ValidationFailed("exactly one of email or user_id is required",
			problem.FieldError{Field: "email", Code: "required", Message: "provide email or user_id"},
			problem.FieldError{Field: "user_id", Code: "required", Message: "provide email or user_id"}))
		return lookupKey{}, false
	case email != "" && rawUserID != "":
		problem.Write(w, r, problem.ValidationFailed("email and user_id are mutually exclusive",
			problem.FieldError{Field: "email", Code: "conflict", Message: "provide only one of email or user_id"},
			problem.FieldError{Field: "user_id", Code: "conflict", Message: "provide only one of email or user_id"}))
		return lookupKey{}, false
	}

	if rawUserID != "" {
		id, err := uuid.Parse(rawUserID)
		if err != nil {
			problem.Write(w, r, problem.ValidationFailed("user_id must be a UUID",
				problem.FieldError{Field: "user_id", Code: "invalid", Message: "must be a UUID"}))
			return lookupKey{}, false
		}
		return lookupKey{userID: pgtype.UUID{Bytes: id, Valid: true}, byUserID: true}, true
	}

	if len(email) > maxEmailLength || !emailPattern.MatchString(email) {
		problem.Write(w, r, problem.ValidationFailed("email must be a valid email address",
			problem.FieldError{Field: "email", Code: "invalid", Message: "must be a valid email address"}))
		return lookupKey{}, false
	}
	return lookupKey{email: email}, true
}

// resolveLookupTarget turns an already-validated lookupKey into a target
// user_id. A user_id key is returned as-is (no I/O -- organizations.memberships'
// user_id is a soft ref, so a well-formed but unknown-to-identity id simply
// resolves to zero memberships downstream, not an error). An email key
// requires the one external call this endpoint makes for the TARGET
// (UserResolver.ResolveByEmail, organizations.go): found=false (with ok=true)
// means the email matched no known identity -- the caller should render an
// empty result, not an error (see platformMembershipListResponse's doc
// comment). ok=false means a problem response has already been written (a
// 502/500 resolver failure).
func resolveLookupTarget(w http.ResponseWriter, r *http.Request, resolver UserResolver, key lookupKey) (userID pgtype.UUID, found bool, ok bool) {
	if key.byUserID {
		return key.userID, true, true
	}

	resolved, err := resolver.ResolveByEmail(r.Context(), r.Header.Get("Authorization"), key.email)
	if err != nil {
		if errors.Is(err, ErrUnknownUser) {
			return pgtype.UUID{}, false, true
		}
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "platform membership lookup: resolve by email failed", slog.Any("error", err))
		problem.Write(w, r, identityUnavailable("identity service is unavailable"))
		return pgtype.UUID{}, false, false
	}
	id, err := uuid.Parse(resolved.UserID)
	if err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "platform membership lookup: parse resolved user id failed", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, false, false
	}
	return pgtype.UUID{Bytes: id, Valid: true}, true, true
}
