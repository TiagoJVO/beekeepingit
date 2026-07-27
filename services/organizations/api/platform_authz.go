// Package api (this file) -- the platform-operator authorization path (#466,
// FR-TEN-2, NFR-ROL-1, NFR-SEC-1, D-3, D-32, ADR-0021): a caller carrying a
// VERIFIED `platform_operator: true` claim (authn.Claims.PlatformOperator,
// extracted server-side by servicetemplate/authn.NewMiddleware from the
// signature-verified token -- never trusted from any client-supplied
// header/query param) may act on an organization it is NOT a member of, for
// the explicit, per-endpoint allowlist this story wires it into:
// organizations.go's getOrganization/updateOrganization, invitations.go's
// listMembersHandler, and member_lifecycle.go's removeMemberHandler /
// changeMemberRoleHandler.
//
// SECURITY CONTRACT (read before touching this file):
//
//   - The ONLY signal this file (or anything else in this codebase) may
//     authorize on is authn.Claims.PlatformOperator. NEVER authn.Claims.Raw
//     ["groups"] or the literal string "platform-operator" -- Authentik's
//     managed `profile` scope mapping emits `groups` containing
//     "platform-operator" on BOTH the beekeepingit-pwa and beekeepingit-admin
//     OIDC clients (#465 handoff comment on #466; oidc-integration.md §3.2;
//     auth.md §3.4), so a field-app (PWA) token for an operator ALSO lists
//     that group today. Keying platform authority off `groups` would grant
//     cross-tenant platform access to a long-lived, offline-cached token on
//     a beekeeper's phone. `platform_operator` is minted ONLY for the
//     admin-client token and is the sole safe signal.
//   - This file is strictly ADDITIVE to requireOrgMember/requireOrgAdmin
//     (invitations.go): neither function is modified, and for any caller
//     whose verified Claims do NOT carry platform_operator:true, the two
//     combinators below (requirePlatformOperatorOrOrgMember/
//     requirePlatformOperatorOrOrgAdmin) delegate to them completely
//     unchanged -- same call, same arguments, same return. ADR-0002's
//     404-not-403 rule for every other caller is therefore provably intact:
//     it is the exact same code path that shipped before this story.
//   - The platform path is checked FIRST (before any membership lookup) and,
//     when the claim is present, is taken UNCONDITIONALLY for that request --
//     it never falls back to the membership path even if the operator also
//     happens to hold an ordinary membership in the target org. This keeps
//     the two paths mutually exclusive and independently reasoned about
//     (never both attempted, never a partial mix), at the cost of a minor
//     product nuance flagged in ADR-0021's Consequences section: an operator
//     who is also a genuine member of the org they're acting on is reported
//     the platform-operator role, not their real membership role.
//   - The platform path still requires {orgId} to resolve to a REAL
//     organization -- a verified operator hitting a nonexistent id still
//     gets an ordinary 404, exactly like every other caller would.
//   - Every grant through this path is logged distinctly (at INFO, so it is
//     never confused with the deny-only WARN logging elsewhere in this
//     package) -- the single most security-relevant fact about a request
//     (a verified operator acting OUTSIDE their own org) belongs in the log
//     stream even on success. This is the recoverability signal #470's
//     audit-attribution story can build on; see this file's and ADR-0021's
//     notes on why it is not (yet) persisted as its own audit_log column.
//
// Extension point for #467 (list organizations) / #468 (cross-org membership
// lookup): both are NEW endpoints with no existing membership check to
// extend. They should NOT call requirePlatformOperatorOrOrgMember/
// ...OrgAdmin (those assume an {orgId} path param and an existing
// member-or-404 fallback) -- instead, call isPlatformOperator(r) directly at
// the top of the handler and problem.Write(w, r, problem.Forbidden(...)) (not
// NotFound -- there is no {orgId} to hide the existence of) when it reports
// false. See this file's doc comment on isPlatformOperator for why it, not
// authn.Claims.PlatformOperator directly, is the sanctioned read site.
package api

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// authorizedViaPlatformOperator is the callerMembership.AuthorizedVia value
// the platform path sets -- see callerMembership's doc comment
// (organizations.go). The membership path (requireOrgMember/requireOrgAdmin)
// never sets AuthorizedVia, leaving it at its zero value "".
const authorizedViaPlatformOperator = "platform_operator"

// platformOperatorRole is the callerMembership.Role a platform-operator-
// authorized caller is given for the organization it acts on. There is no
// membership row to read a real admin/user role from -- by definition this
// path only ever applies to a caller who is NOT a member. "admin" is used
// deliberately, not a third sentinel value: every endpoint this path is
// wired into already required org-admin for the ordinary path (get/list
// members are the sole read-level exceptions, gated by requireOrgMember, and
// grant the same full capability here too), and the wire contract's Role
// enum (contracts/openapi/organizations.openapi.yaml) is closed to
// [admin, user] -- adding a third value would be a contract/client change
// out of this story's scope (#466 is the authorization MECHANISM, not a new
// API shape). Never written to the memberships table.
const platformOperatorRole = "admin"

// isPlatformOperator reports whether the request's verified Claims
// (authn.NewMiddleware, populated ONLY from the signed token's decoded
// payload) carry platform_operator:true. This is the ONE sanctioned read
// site for that claim in this service -- #467/#468 should call this exact
// function (or its own copy of this exact one-liner, since it has no
// service-specific dependencies) rather than reading
// authn.Claims.PlatformOperator inline, so a future audit of "everywhere
// this codebase makes a platform-tier authorization decision" is a search
// for this function's call sites, not a grep for a struct field that could
// be read anywhere.
func isPlatformOperator(r *http.Request) bool {
	claims, ok := authn.FromContext(r.Context())
	return ok && claims.PlatformOperator
}

// requirePlatformOperatorOrOrgMember is requireOrgMember's platform-path
// counterpart (#466): a verified platform operator may act on ANY
// organization via {orgId}; every other caller goes through requireOrgMember
// completely unchanged. Wired into organizations.go's getOrganization (the
// one read-level, non-admin-gated route in this story's scope).
func requirePlatformOperatorOrOrgMember(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	if isPlatformOperator(r) {
		return platformOperatorMembership(w, r, q, resolver)
	}
	return requireOrgMember(w, r, q, resolver)
}

// requirePlatformOperatorOrOrgAdmin is requireOrgAdmin's platform-path
// counterpart (#466) -- same shape as requirePlatformOperatorOrOrgMember,
// for this story's admin-gated writes: updateOrganization, listMembersHandler,
// removeMemberHandler, changeMemberRoleHandler. The platform path grants the
// same full capability requireOrgAdmin would for an actual org admin -- there
// is no separate "platform member" vs "platform admin" tier.
func requirePlatformOperatorOrOrgAdmin(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	if isPlatformOperator(r) {
		return platformOperatorMembership(w, r, q, resolver)
	}
	return requireOrgAdmin(w, r, q, resolver)
}

// platformOperatorMembership builds the callerMembership for a request
// already known to carry the verified platform_operator claim (both
// combinators above check isPlatformOperator before calling this). It:
//
//  1. Parses {orgId} and asserts it resolves to a REAL organization -- a
//     nonexistent id is an ordinary 404 here too, exactly like the
//     membership path would produce for ANY caller, so a platform operator
//     can't distinguish "no such org" from any other not-found response.
//  2. Resolves the operator's OWN identity.users row (not membership -- an
//     operator need not, and typically does not, belong to the org being
//     acted on) via the same UserResolver.Resolve the membership path's
//     resolveCaller uses, so audit_log.actor_user_id still references a
//     real, known user (history.md §3).
//  3. Logs the grant at INFO (see this file's package doc) and returns a
//     callerMembership scoped to the target org, actor = the operator's own
//     user id, Role = platformOperatorRole, AuthorizedVia =
//     authorizedViaPlatformOperator.
func platformOperatorMembership(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	claims, ok := authn.FromContext(r.Context())
	if !ok {
		// Programming error: isPlatformOperator already returned true, which
		// requires FromContext to have succeeded moments ago.
		problem.Write(w, r, problem.Internal())
		return callerMembership{}, false
	}

	orgID, err := uuid.Parse(chi.URLParam(r, "orgId"))
	if err != nil {
		problem.Write(w, r, problem.NotFound("organization not found"))
		return callerMembership{}, false
	}
	orgPk := pgtype.UUID{Bytes: orgID, Valid: true}

	if _, err := q.GetOrganization(r.Context(), orgPk); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("organization not found"))
			return callerMembership{}, false
		}
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "platform operator: get organization failed", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return callerMembership{}, false
	}

	// Resolve the operator's own identity.users row -- the same identity
	// call resolveCaller makes for the ordinary path (organizations.go),
	// just without the membership lookup that follows it there.
	resolved, err := resolver.Resolve(r.Context(), r.Header.Get("Authorization"), claims.Sub)
	if err != nil {
		if errors.Is(err, ErrUnknownUser) {
			problem.Write(w, r, problem.Forbidden("caller is not a known user"))
			return callerMembership{}, false
		}
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "platform operator: resolve caller failed", slog.Any("error", err))
		problem.Write(w, r, identityUnavailable("identity service is unavailable"))
		return callerMembership{}, false
	}
	operatorUserID, err := uuid.Parse(resolved.UserID)
	if err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "platform operator: parse resolved user id failed", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return callerMembership{}, false
	}

	logging.FromContext(r.Context()).InfoContext(r.Context(), "authz granted: platform operator acting on an organization outside their membership",
		slog.String("organization_id", uuidString(orgPk)),
		slog.String("actor_user_id", resolved.UserID),
		slog.String("path", r.URL.Path),
		slog.String("method", r.Method),
	)

	return callerMembership{
		OrgID:         orgPk,
		UserID:        pgtype.UUID{Bytes: operatorUserID, Valid: true},
		Role:          platformOperatorRole,
		AuthorizedVia: authorizedViaPlatformOperator,
	}, true
}
