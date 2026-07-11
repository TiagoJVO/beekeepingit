// Package devseed holds the canonical dev/CI-only seed identifiers for the
// M0 walking-skeleton slice (docs/architecture/walking-skeleton.md §4.5).
//
// The slice SEEDS the identity/org rows login needs rather than onboarding
// them (profile/org creation is EPIC-01). These constants are the single
// source of truth so every piece that must agree on the same principal —
// identity's users row, organizations' org + admin membership, the IdP
// blueprint's seed user, and the e2e test's login — stays in lock-step.
//
// NOT for production: services only apply the seed when SEED_DEV_DATA=true,
// and EPIC-01's real onboarding replaces it entirely.
package devseed

const (
	// OidcSub is the test user's OIDC subject. Under Authentik it is the seed
	// user's `attributes.upn`, which sub_mode: user_upn surfaces as the token
	// `sub` (docs/architecture/oidc-integration.md §4) — so it MUST equal that
	// blueprint `upn` for a verified token's `sub` to resolve (auth.md §5.1
	// step 1) to UserID below. The value is unchanged from the prior IdP setup
	// (§4: "oidc_sub keeps its prior value") for continuity.
	OidcSub = "11111111-1111-4111-8111-111111111111"

	// The identity.users row the OidcSub resolves to.
	UserID     = "a0000000-0000-7000-8000-000000000001"
	UserName   = "Dev Beekeeper"
	UserEmail  = "dev@beekeepingit.local"
	UserLocale = "en"

	// The tenant the user is an active member of (organizations schema).
	OrganizationID   = "b0000000-0000-7000-8000-000000000001"
	OrganizationName = "Dev Apiary Co."

	// The active admin membership tying UserID to OrganizationID. The slice
	// only needs "active member"; role-differentiated authz is #28.
	MembershipID   = "c0000000-0000-7000-8000-000000000001"
	MembershipRole = "admin"
)
