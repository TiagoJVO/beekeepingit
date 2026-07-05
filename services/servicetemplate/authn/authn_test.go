package authn_test

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
)

const testAudience = "beekeepingit-example"

// testIDP is a minimal stand-in for Keycloak's OIDC discovery + JWKS
// endpoints, serving a JWKS that tests can mutate at runtime to exercise
// key-rotation ("unknown kid") handling — no real Keycloak container needed.
type testIDP struct {
	mu   sync.Mutex
	keys []jose.JSONWebKey
	srv  *httptest.Server
}

func newTestIDP(t *testing.T) *testIDP {
	idp := &testIDP{}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{
			"issuer":   idp.srv.URL,
			"jwks_uri": idp.srv.URL + "/jwks",
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, _ *http.Request) {
		idp.mu.Lock()
		defer idp.mu.Unlock()
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: append([]jose.JSONWebKey{}, idp.keys...)})
	})
	idp.srv = httptest.NewServer(mux)
	t.Cleanup(idp.srv.Close)
	return idp
}

func (idp *testIDP) addKey(pub jose.JSONWebKey) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	idp.keys = append(idp.keys, pub)
}

func generateKey(t *testing.T, kid string) (*rsa.PrivateKey, jose.JSONWebKey) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	pub := jose.JSONWebKey{Key: &priv.PublicKey, KeyID: kid, Algorithm: "RS256", Use: "sig"}
	return priv, pub
}

func mintToken(t *testing.T, priv *rsa.PrivateKey, kid, issuer string, expiry time.Time, extra map[string]any) string {
	t.Helper()
	signer, err := jose.NewSigner(
		jose.SigningKey{Algorithm: jose.RS256, Key: priv},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid),
	)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}

	claims := jwt.Claims{
		Issuer:   issuer,
		Subject:  "user-123",
		Audience: jwt.Audience{testAudience},
		Expiry:   jwt.NewNumericDate(expiry),
		IssuedAt: jwt.NewNumericDate(time.Now()),
	}
	raw, err := jwt.Signed(signer).Claims(claims).Claims(extra).Serialize()
	if err != nil {
		t.Fatalf("serialize token: %v", err)
	}
	return raw
}

func newMiddleware(t *testing.T, issuer string) func(http.Handler) http.Handler {
	t.Helper()
	mw, err := authn.NewMiddleware(context.Background(), authn.Config{IssuerURL: issuer, Audience: testAudience})
	if err != nil {
		t.Fatalf("NewMiddleware: %v", err)
	}
	return mw
}

func protectedHandler(captured *authn.Claims) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, ok := authn.FromContext(r.Context()); ok {
			*captured = c
		}
		w.WriteHeader(http.StatusOK)
	})
}

func doRequest(mw func(http.Handler) http.Handler, next http.Handler, authHeader string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/example-items", nil)
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	mw(next).ServeHTTP(rec, req)
	return rec
}

func TestMiddleware_ValidToken_PopulatesClaims(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	mw := newMiddleware(t, idp.srv.URL)

	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), map[string]any{
		"email": "beekeeper@example.com", "email_verified": true,
	})

	var claims authn.Claims
	rec := doRequest(mw, protectedHandler(&claims), "Bearer "+token)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body = %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if claims.Sub != "user-123" {
		t.Errorf("Sub = %q, want %q", claims.Sub, "user-123")
	}
	if claims.Email != "beekeeper@example.com" || !claims.EmailVerified {
		t.Errorf("Email/EmailVerified = %q/%v, want beekeeper@example.com/true", claims.Email, claims.EmailVerified)
	}
}

func TestMiddleware_ExpiredToken_Rejected(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	mw := newMiddleware(t, idp.srv.URL)

	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(-time.Hour), nil)

	rec := doRequest(mw, protectedHandler(new(authn.Claims)), "Bearer "+token)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want application/problem+json", ct)
	}
}

func TestMiddleware_WrongAudience_Rejected(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	mw, err := authn.NewMiddleware(context.Background(), authn.Config{IssuerURL: idp.srv.URL, Audience: "some-other-client"})
	if err != nil {
		t.Fatalf("NewMiddleware: %v", err)
	}

	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), nil)

	rec := doRequest(mw, protectedHandler(new(authn.Claims)), "Bearer "+token)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestMiddleware_MissingHeader_Rejected(t *testing.T) {
	idp := newTestIDP(t)
	mw := newMiddleware(t, idp.srv.URL)

	rec := doRequest(mw, protectedHandler(new(authn.Claims)), "")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestMiddleware_MalformedScheme_Rejected(t *testing.T) {
	idp := newTestIDP(t)
	mw := newMiddleware(t, idp.srv.URL)

	rec := doRequest(mw, protectedHandler(new(authn.Claims)), "Token abc.def.ghi")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

// TestMiddleware_UnknownKID_TriggersJWKSRefetch proves key rotation works:
// a token signed with a key the JWKS didn't have at startup still verifies,
// because go-oidc's RemoteKeySet refetches the JWKS on an unrecognized kid.
func TestMiddleware_UnknownKID_TriggersJWKSRefetch(t *testing.T) {
	idp := newTestIDP(t)
	_, pubA := generateKey(t, "key-a")
	idp.addKey(pubA)
	mw := newMiddleware(t, idp.srv.URL) // caches a JWKS containing only key-a

	// Simulate rotation: the IdP now also serves key-b, signed *after* the
	// middleware's initial JWKS fetch.
	privB, pubB := generateKey(t, "key-b")
	idp.addKey(pubB)

	token := mintToken(t, privB, "key-b", idp.srv.URL, time.Now().Add(time.Hour), nil)

	var claims authn.Claims
	rec := doRequest(mw, protectedHandler(&claims), "Bearer "+token)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d (JWKS refetch on unknown kid should have succeeded), body = %s",
			rec.Code, http.StatusOK, rec.Body.String())
	}
	if claims.Sub != "user-123" {
		t.Errorf("Sub = %q, want %q", claims.Sub, "user-123")
	}
}
