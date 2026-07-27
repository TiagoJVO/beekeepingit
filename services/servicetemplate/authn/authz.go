// Package authn (this file) — the shared, reusable authorization checks that
// sit on top of NewOrgResolver's resolved Claims (auth.md §5.2/§5.3, #28's
// AC: "a shared backend authorization middleware enforces both role and
// organization_id scope on protected endpoints"). It generalizes the
// role/org-scope pattern organizations/api/invitations.go's requireOrgAdmin
// proved out for #27, so apiaries — and any future domain service — get the
// same mechanism instead of a per-service reimplementation.
//
// Every denial here is logged via the request-scoped logger
// (servicetemplate/logging.FromContext), matching NewOrgResolver's own
// denial logging and #28's AC ("the denial is logged"). Only verified,
// server-derived facts (Claims.Role, Claims.OrganizationID — both resolved
// server-side by NewOrgResolver, never a client-supplied header/body field)
// are used in these decisions.
package authn

import (
	"log/slog"
	"net/http"
	"slices"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// RequireRole builds middleware that rejects a request unless the caller's
// resolved Claims.Role (auth.md §5.1, set by NewOrgResolver) is one of
// allowedRoles. Mount it AFTER NewOrgResolver (it reads the Role NewOrgResolver
// derived from the caller's active membership — never a client-supplied
// value). A missing/unresolved Role is a wiring bug (NewOrgResolver mounted
// without this behind it) and fails closed as 500, not 403, so it's caught in
// testing rather than silently admitting every caller.
//
// A caller whose role isn't allowed gets 403 Forbidden (auth.md §5.3: "admin-
// only operations are rejected for non-admins", #28 AC), and the denial is
// logged with the caller's resolved org/role/route so it's auditable
// (#28 AC: "the denial is logged").
func RequireRole(allowedRoles ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := FromContext(r.Context())
			if !ok || claims.OrganizationID == "" || claims.Role == "" {
				// Programming error: RequireRole was mounted without
				// NewMiddleware+NewOrgResolver in front of it.
				problem.Write(w, r, problem.Internal())
				return
			}
			if slices.Contains(allowedRoles, claims.Role) {
				next.ServeHTTP(w, r)
				return
			}

			logging.FromContext(r.Context()).WarnContext(r.Context(), "authz denied: role not permitted",
				slog.String("organization_id", claims.OrganizationID),
				slog.String("role", claims.Role),
				slog.Any("allowed_roles", allowedRoles),
				slog.String("path", r.URL.Path),
			)
			problem.Write(w, r, problem.Forbidden("caller's role does not permit this action"))
		})
	}
}

// RequireOrgPath builds middleware for routes that carry an organization id
// in the URL path (an org-*management* resource, e.g.
// "/organizations/{orgId}/…" — auth.md §5.1 step 2: "the one place an org id
// appears in a URL... the service asserts {orgId} matches the caller's
// membership — the path never widens scope"). orgIDParam names the chi URL
// param (e.g. "orgId").
//
// A path org id that doesn't match the caller's resolved OrganizationID gets
// 404, not 403 (ADR-0002, api-contracts.md §9): the API never confirms
// another org's existence to a non-member. The denial is still logged
// (#28 AC), same as RequireRole.
//
// Mount AFTER NewOrgResolver. urlParam is injected so this package doesn't
// need a direct chi dependency; pass chi.URLParam.
func RequireOrgPath(orgIDParam string, urlParam func(r *http.Request, key string) string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := FromContext(r.Context())
			if !ok || claims.OrganizationID == "" {
				problem.Write(w, r, problem.Internal())
				return
			}
			callerOrg, err := uuid.Parse(claims.OrganizationID)
			if err != nil {
				// The resolved OrganizationID is server-derived (NewOrgResolver);
				// a non-UUID value here is a wiring bug, not a caller error.
				problem.Write(w, r, problem.Internal())
				return
			}
			// Parse-then-compare (not a raw string match) so a
			// differently-cased but equal UUID in the path still matches —
			// mirrors every existing {orgId} handler (invitations.go,
			// organizations.go).
			requested, err := uuid.Parse(urlParam(r, orgIDParam))
			if err != nil || requested != callerOrg {
				logging.FromContext(r.Context()).WarnContext(r.Context(), "authz denied: path organization_id outside caller's scope",
					slog.String("organization_id", claims.OrganizationID),
					slog.String("path", r.URL.Path),
				)
				problem.Write(w, r, problem.NotFound("organization not found"))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
