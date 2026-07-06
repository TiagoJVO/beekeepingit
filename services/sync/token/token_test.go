package token_test

import (
	"crypto/x509"
	"encoding/pem"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"

	"github.com/TiagoJVO/beekeepingit/services/sync/token"
)

func TestMint_ProducesVerifiableOrgScopedToken(t *testing.T) {
	priv, generated, err := token.LoadOrGenerateKey("")
	if err != nil {
		t.Fatalf("LoadOrGenerateKey: %v", err)
	}
	if !generated {
		t.Error("empty key data should generate an ephemeral key")
	}

	m, err := token.NewMinter(priv, "https://sync.beekeepingit.local", "powersync", time.Minute)
	if err != nil {
		t.Fatalf("NewMinter: %v", err)
	}

	raw, exp, err := m.Mint("user-sub-1", "org-uuid-1")
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	if d := time.Until(exp); d <= 0 || d > time.Minute+time.Second {
		t.Errorf("expiry = %v from now, want ~1m", d)
	}

	parsed, err := jwt.ParseSigned(raw, []jose.SignatureAlgorithm{jose.RS256})
	if err != nil {
		t.Fatalf("ParseSigned: %v", err)
	}
	var claims jwt.Claims
	var extra struct {
		OrganizationID string `json:"organization_id"`
	}
	if err := parsed.Claims(&priv.PublicKey, &claims, &extra); err != nil {
		t.Fatalf("verify claims: %v", err)
	}
	if claims.Subject != "user-sub-1" {
		t.Errorf("sub = %q, want user-sub-1", claims.Subject)
	}
	if claims.Issuer != "https://sync.beekeepingit.local" {
		t.Errorf("iss = %q", claims.Issuer)
	}
	if len(claims.Audience) != 1 || claims.Audience[0] != "powersync" {
		t.Errorf("aud = %v, want [powersync]", claims.Audience)
	}
	if extra.OrganizationID != "org-uuid-1" {
		t.Errorf("organization_id = %q, want org-uuid-1", extra.OrganizationID)
	}
}

func TestJWKS_MatchesSigningKid(t *testing.T) {
	priv, _, _ := token.LoadOrGenerateKey("")
	m, err := token.NewMinter(priv, "iss", "aud", time.Minute)
	if err != nil {
		t.Fatalf("NewMinter: %v", err)
	}
	raw, _, err := m.Mint("s", "o")
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}

	jwks := m.JWKS()
	if len(jwks.Keys) != 1 {
		t.Fatalf("JWKS keys = %d, want 1", len(jwks.Keys))
	}
	parsed, err := jwt.ParseSigned(raw, []jose.SignatureAlgorithm{jose.RS256})
	if err != nil {
		t.Fatalf("ParseSigned: %v", err)
	}
	if got := parsed.Headers[0].KeyID; got != jwks.Keys[0].KeyID {
		t.Errorf("token kid %q != JWKS kid %q", got, jwks.Keys[0].KeyID)
	}
}

func TestLoadOrGenerateKey_ParsesPEM(t *testing.T) {
	gen, _, err := token.LoadOrGenerateKey("")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(gen)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	pemData := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))

	loaded, generated, err := token.LoadOrGenerateKey(pemData)
	if err != nil {
		t.Fatalf("load PEM: %v", err)
	}
	if generated {
		t.Error("loading a PEM should not report generated")
	}
	if loaded.N.Cmp(gen.N) != 0 {
		t.Error("loaded key modulus differs from the original")
	}
}
