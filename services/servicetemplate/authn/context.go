package authn

import "context"

// Claims is the verified caller identity extracted from a Keycloak access
// token. Org-scoped role/tenancy resolution is a separate concern built on
// top of this (EPIC-01) — Claims carries authentication, not authorization.
type Claims struct {
	Sub           string
	Email         string
	EmailVerified bool
	Raw           map[string]any
}

type claimsKey struct{}

// FromContext returns the Claims stored by the middleware built by
// NewMiddleware, or false outside an authenticated request.
func FromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}
