// Package authn is the shared JWT/JWKS authentication middleware: it
// verifies an OIDC-issued bearer access token via the issuer's OIDC
// discovery document + JWKS (coreos/go-oidc/v3), rejecting invalid/expired
// tokens with the standard problem+json error format
// (docs/architecture/auth.md §4). It depends only on standard OIDC, not on
// any particular provider (oidc-integration.md §1). Org-scoped authorization —
// which organization, which role — is a separate, later concern (EPIC-01);
// this package only establishes who the caller is.
package authn

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// Config configures token verification.
type Config struct {
	IssuerURL string // OIDC issuer (the token's `iss`), e.g. https://auth.example/application/o/beekeepingit/
	Audience  string // expected client id (checked against the token's aud)
	// DiscoveryURL, when set, is where the OIDC discovery document is fetched,
	// while IssuerURL stays the expected token `iss`. Dev/CI: lets an in-cluster
	// service reach the issuer over plain HTTP (an internal Service URL) while
	// still validating a browser token whose `iss` is the external HTTPS issuer
	// URL (go-oidc's InsecureIssuerURLContext bridges the mismatch). Empty in
	// production, where discovery and issuer are the same URL.
	DiscoveryURL string
}

// NewMiddleware builds JWT-validating middleware against cfg. It fetches the
// issuer's OIDC discovery document once at startup; go-oidc caches the JWKS
// internally and refetches it on an unrecognized kid (key rotation).
func NewMiddleware(ctx context.Context, cfg Config) (func(http.Handler) http.Handler, error) {
	discoverAt := cfg.IssuerURL
	if cfg.DiscoveryURL != "" {
		// Fetch discovery from DiscoveryURL but trust IssuerURL as the issuer.
		ctx = oidc.InsecureIssuerURLContext(ctx, cfg.IssuerURL)
		discoverAt = cfg.DiscoveryURL
	}
	provider, err := oidc.NewProvider(ctx, discoverAt)
	if err != nil {
		return nil, fmt.Errorf("authn: discover issuer %q: %w", cfg.IssuerURL, err)
	}
	verifier := provider.Verifier(&oidc.Config{ClientID: cfg.Audience})

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			rawToken, ok := bearerToken(r)
			if !ok {
				problem.Write(w, r, problem.Unauthorized("missing or malformed Authorization bearer token"))
				return
			}

			idToken, err := verifier.Verify(r.Context(), rawToken)
			if err != nil {
				problem.Write(w, r, problem.Unauthorized("invalid or expired token"))
				return
			}

			var raw map[string]any
			if err := idToken.Claims(&raw); err != nil {
				problem.Write(w, r, problem.Unauthorized("malformed token claims"))
				return
			}
			claims := Claims{Sub: idToken.Subject, Raw: raw}
			if email, ok := raw["email"].(string); ok {
				claims.Email = email
			}
			if verified, ok := raw["email_verified"].(bool); ok {
				claims.EmailVerified = verified
			}

			ctx := context.WithValue(r.Context(), claimsKey{}, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}, nil
}

func bearerToken(r *http.Request) (string, bool) {
	const prefix = "Bearer "
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, prefix) {
		return "", false
	}
	token := strings.TrimSpace(strings.TrimPrefix(h, prefix))
	return token, token != ""
}
