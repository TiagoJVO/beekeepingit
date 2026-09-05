package authn

import "context"

// Claims is the verified caller identity extracted from an OIDC access
// token, optionally enriched with the request's org-scoped authorization.
//
// NewMiddleware populates only the authentication fields (Sub, Email, …).
// The org-scoped fields (UserID, OrganizationID, Role) are filled in by the
// NewOrgResolver middleware layered on top (auth.md §5.1, walking-skeleton.md
// §4.2); they are empty on Claims that only passed through NewMiddleware.
type Claims struct {
	Sub   string
	Email string
	// Name is the token's standard OIDC `name` claim — DISPLAY DATA ONLY,
	// used to seed the profile row at first sight (FR-ONB-1, #365 follow-up).
	//
	// Extraction fails SOFT, deliberately unlike EmailVerified's fail-CLOSED:
	// an absent claim, or one present as anything other than a JSON string,
	// leaves this the zero value "", which is inert — the user simply fills
	// the field in during onboarding. The opposite choice would be actively
	// harmful: rejecting a token over a mis-mapped display-name scope would
	// lock every user of that provider out of the product to protect a value
	// that prefills a text box.
	//
	// SECURITY: never an authorization input. The provider lets a user edit
	// this freely and no claim vouches for it — there is no `name_verified`.
	// It is not an identifier: it is neither unique nor stable.
	Name          string
	EmailVerified bool
	// PlatformOperator is the verified `platform_operator` boolean claim
	// (oidc-integration.md §3.2, EPIC-18 #465/#466): true only for a token
	// minted by the `beekeepingit-admin` OIDC client for a caller in the
	// IdP's `platform-operator` group. Populated by NewMiddleware from the
	// SIGNATURE-VERIFIED token's decoded claims only — never from a
	// client-supplied header/query param — mirroring EmailVerified's
	// fail-closed extraction: absent, or present as anything other than a
	// literal JSON boolean, parses as false.
	//
	// SECURITY: this is the ONLY claim a service may authorize platform-tier
	// access on. The `groups` claim (in Raw) also lists `platform-operator`
	// but is emitted on BOTH the pwa and admin OIDC clients (auth.md §3.4,
	// oidc-integration.md §3.2) — authorizing on it would grant cross-tenant
	// platform access to a long-lived, offline-cached PWA token on a
	// beekeeper's phone. Never read Raw["groups"] or the literal string
	// "platform-operator" for an authorization decision.
	PlatformOperator bool
	Raw              map[string]any

	// Org-scoped authorization, resolved from membership by NewOrgResolver.
	UserID         string
	OrganizationID string
	Role           string
}

type claimsKey struct{}

// FromContext returns the Claims stored by the middleware built by
// NewMiddleware, or false outside an authenticated request.
func FromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}

// ContextWithClaims returns ctx carrying c, exactly as NewMiddleware /
// NewOrgResolver do. Exposed for composing middleware and for tests that need
// to drive downstream handlers with a known identity without a live token.
func ContextWithClaims(ctx context.Context, c Claims) context.Context {
	return context.WithValue(ctx, claimsKey{}, c)
}
