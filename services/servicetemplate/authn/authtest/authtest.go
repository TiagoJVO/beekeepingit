// Package authtest provides a minimal in-process stand-in for Keycloak's
// OIDC discovery + JWKS endpoints, plus RS256 token minting, so services
// built on the shared template can exercise their authn.NewMiddleware chain
// over real HTTP in tests without a live Keycloak. It mirrors the inline
// helper in servicetemplate/example's own test, hoisted here so every domain
// service (identity, organizations, apiaries, sync) reuses one implementation.
package authtest

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// IDP is a running fake OIDC issuer with a single signing key.
type IDP struct {
	Server *httptest.Server
	priv   *rsa.PrivateKey
	kid    string
}

// NewIDP starts a discovery + JWKS server signed by a fresh RSA key and
// registers cleanup on t.
func NewIDP(t *testing.T) *IDP {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("authtest: generate RSA key: %v", err)
	}
	idp := &IDP{priv: priv, kid: "test-key-1"}

	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{
			"issuer":   idp.Server.URL,
			"jwks_uri": idp.Server.URL + "/jwks",
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
			{Key: &idp.priv.PublicKey, KeyID: idp.kid, Algorithm: "RS256", Use: "sig"},
		}})
	})
	idp.Server = httptest.NewServer(mux)
	t.Cleanup(idp.Server.Close)
	return idp
}

// Issuer is the issuer URL to pass as authn.Config.IssuerURL.
func (i *IDP) Issuer() string { return i.Server.URL }

// Mint returns a signed RS256 access token for sub with the given audience,
// valid for one hour.
func (i *IDP) Mint(t *testing.T, sub, audience string) string {
	t.Helper()
	signer, err := jose.NewSigner(
		jose.SigningKey{Algorithm: jose.RS256, Key: i.priv},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", i.kid),
	)
	if err != nil {
		t.Fatalf("authtest: new signer: %v", err)
	}
	claims := jwt.Claims{
		Issuer:   i.Server.URL,
		Subject:  sub,
		Audience: jwt.Audience{audience},
		Expiry:   jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt: jwt.NewNumericDate(time.Now()),
	}
	raw, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		t.Fatalf("authtest: serialize token: %v", err)
	}
	return raw
}
