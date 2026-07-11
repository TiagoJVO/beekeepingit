// Package token mints the short-lived, org-scoped PowerSync sync token and
// serves the JWKS PowerSync validates it against (sync.md §3.4, walking-
// skeleton.md §4.3). The token is deliberately separate from the long-lived
// OIDC access token: it is short-TTL so the org claim (mutable domain
// data) can't go stale (auth.md §3.4).
package token

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// Minter signs sync tokens with an RSA key and exposes the matching JWKS.
type Minter struct {
	priv     *rsa.PrivateKey
	kid      string
	issuer   string
	audience string
	ttl      time.Duration
}

// NewMinter builds a Minter. The kid is the key's RFC 7638 thumbprint so it is
// stable for a given key and changes when the key rotates.
func NewMinter(priv *rsa.PrivateKey, issuer, audience string, ttl time.Duration) (*Minter, error) {
	if priv == nil {
		return nil, fmt.Errorf("token: private key is required")
	}
	if issuer == "" || audience == "" {
		return nil, fmt.Errorf("token: issuer and audience are required")
	}
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	pub := jose.JSONWebKey{Key: &priv.PublicKey, Algorithm: string(jose.RS256), Use: "sig"}
	tp, err := pub.Thumbprint(crypto.SHA256)
	if err != nil {
		return nil, fmt.Errorf("token: compute key thumbprint: %w", err)
	}
	return &Minter{
		priv:     priv,
		kid:      base64.RawURLEncoding.EncodeToString(tp),
		issuer:   issuer,
		audience: audience,
		ttl:      ttl,
	}, nil
}

// Mint returns a signed sync token for sub scoped to orgID, plus its expiry.
func (m *Minter) Mint(sub, orgID string) (raw string, expiresAt time.Time, err error) {
	signer, err := jose.NewSigner(
		jose.SigningKey{Algorithm: jose.RS256, Key: m.priv},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", m.kid),
	)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("token: new signer: %w", err)
	}

	now := time.Now()
	exp := now.Add(m.ttl)
	claims := jwt.Claims{
		Issuer:   m.issuer,
		Subject:  sub,
		Audience: jwt.Audience{m.audience},
		Expiry:   jwt.NewNumericDate(exp),
		IssuedAt: jwt.NewNumericDate(now),
	}
	// organization_id is the claim PowerSync parameterizes its Sync Rules on
	// (sync.md §3.4); the org bucket is keyed by it.
	extra := map[string]any{"organization_id": orgID}

	raw, err = jwt.Signed(signer).Claims(claims).Claims(extra).Serialize()
	if err != nil {
		return "", time.Time{}, fmt.Errorf("token: serialize: %w", err)
	}
	return raw, exp, nil
}

// JWKS returns the public JWK set PowerSync fetches to validate sync tokens.
func (m *Minter) JWKS() jose.JSONWebKeySet {
	return jose.JSONWebKeySet{Keys: []jose.JSONWebKey{
		{Key: &m.priv.PublicKey, KeyID: m.kid, Algorithm: string(jose.RS256), Use: "sig"},
	}}
}

// LoadOrGenerateKey parses a PEM-encoded RSA private key (PKCS#1 or PKCS#8),
// or generates an ephemeral 2048-bit key when pemData is empty. A generated
// key is dev/CI-only — production supplies a stable key via a mounted secret
// (EPIC-14) so tokens survive restarts.
func LoadOrGenerateKey(pemData string) (*rsa.PrivateKey, bool, error) {
	if pemData == "" {
		priv, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return nil, false, fmt.Errorf("token: generate key: %w", err)
		}
		return priv, true, nil
	}
	block, _ := pem.Decode([]byte(pemData))
	if block == nil {
		return nil, false, fmt.Errorf("token: no PEM block found in key data")
	}
	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, false, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, false, fmt.Errorf("token: parse private key: %w", err)
	}
	rsaKey, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, false, fmt.Errorf("token: key is not an RSA private key")
	}
	return rsaKey, false, nil
}
