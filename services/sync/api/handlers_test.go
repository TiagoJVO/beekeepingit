package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/sync/token"
)

func withOrgClaims(r *http.Request) *http.Request {
	claims := authn.Claims{Sub: "user-1", UserID: "user-1", OrganizationID: "org-1", Role: "user"}
	return r.WithContext(authn.ContextWithClaims(r.Context(), claims))
}

// countingApiaries is a minimal stand-in for the owning service, used to
// prove BatchHandler never forwards a rejected batch upstream.
func countingApiaries(t *testing.T) (*httptest.Server, *int32) {
	t.Helper()
	var validateHits int32
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/sync/validate", func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&validateHits, 1)
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/internal/sync/apply", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"results":[]}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server, &validateHits
}

// TestBatchHandler_OversizedBody_Rejected proves HIGH #1: a body larger than
// maxBatchBytes must be clearly rejected (422 validation problem), not
// silently truncated and forwarded to the owning service.
func TestBatchHandler_OversizedBody_Rejected(t *testing.T) {
	server, validateHits := countingApiaries(t)
	coord, err := NewCoordinator(server.URL, server.URL, server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	oversized := bytes.Repeat([]byte("a"), maxBatchBytes+1)
	req := httptest.NewRequest(http.MethodPost, "/v1/sync/batch", bytes.NewReader(oversized))
	req = withOrgClaims(req)
	rec := httptest.NewRecorder()

	BatchHandler(coord)(rec, req)

	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want %d (unprocessable entity), body = %s", rec.Code, http.StatusUnprocessableEntity, rec.Body.String())
	}
	var p problem.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode problem+json body: %v (body = %s)", err, rec.Body.String())
	}
	if p.Code != "validation.failed" {
		t.Errorf("code = %q, want validation.failed", p.Code)
	}
	if !strings.Contains(strings.ToLower(p.Detail), "batch size") && !strings.Contains(strings.ToLower(p.Detail), "maximum") {
		t.Errorf("detail = %q, want a clear oversized-batch message", p.Detail)
	}
	if atomic.LoadInt32(validateHits) != 0 {
		t.Errorf("validate was called %d times for a rejected oversized batch, want 0 (never forwarded)", *validateHits)
	}
}

// TestBatchHandler_BodyAtMaxSize_NotRejected is the boundary companion: a
// body of exactly maxBatchBytes must still be accepted and forwarded.
func TestBatchHandler_BodyAtMaxSize_NotRejected(t *testing.T) {
	server, validateHits := countingApiaries(t)
	coord, err := NewCoordinator(server.URL, server.URL, server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	// Pad a valid-ish JSON payload out to exactly maxBatchBytes with
	// whitespace so it's still parseable JSON at the byte cap.
	payload := []byte(`{"ops":[]}`)
	padding := bytes.Repeat([]byte(" "), maxBatchBytes-len(payload))
	atMax := append(append([]byte{}, payload...), padding...)
	if len(atMax) != maxBatchBytes {
		t.Fatalf("test setup: body = %d bytes, want %d", len(atMax), maxBatchBytes)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/sync/batch", bytes.NewReader(atMax))
	req = withOrgClaims(req)
	rec := httptest.NewRecorder()

	BatchHandler(coord)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if atomic.LoadInt32(validateHits) != 1 {
		t.Errorf("validate was called %d times for an at-cap batch, want 1 (forwarded)", *validateHits)
	}
}

// TestBatchHandler_MissingOrgClaims_ReturnsInternalProblem locks in the
// org-claims gate's current behavior so extracting it into a shared helper
// (requireOrgClaims) can't silently change it.
func TestBatchHandler_MissingOrgClaims_ReturnsInternalProblem(t *testing.T) {
	server, _ := countingApiaries(t)
	coord, err := NewCoordinator(server.URL, server.URL, server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/sync/batch", bytes.NewReader([]byte(`{"ops":[]}`)))
	rec := httptest.NewRecorder()

	BatchHandler(coord)(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500, body = %s", rec.Code, rec.Body.String())
	}
}

// TestTokenHandler_MissingOrgClaims_ReturnsInternalProblem is the same
// regression guard as above, for the other handler sharing the org-claims
// gate.
func TestTokenHandler_MissingOrgClaims_ReturnsInternalProblem(t *testing.T) {
	priv, _, err := token.LoadOrGenerateKey("")
	if err != nil {
		t.Fatalf("LoadOrGenerateKey: %v", err)
	}
	minter, err := token.NewMinter(priv, "iss", "aud", time.Minute)
	if err != nil {
		t.Fatalf("NewMinter: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/sync/token", nil)
	rec := httptest.NewRecorder()

	TokenHandler(minter)(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500, body = %s", rec.Code, rec.Body.String())
	}
}

// TestJWKSHandler_ServesPublicKeySet is MEDIUM #5: JWKSHandler previously had
// zero test coverage. It must serve the minter's public key set through the
// real HTTP handler, not just the underlying token.Minter.JWKS() method.
func TestJWKSHandler_ServesPublicKeySet(t *testing.T) {
	priv, _, err := token.LoadOrGenerateKey("")
	if err != nil {
		t.Fatalf("LoadOrGenerateKey: %v", err)
	}
	minter, err := token.NewMinter(priv, "iss", "aud", time.Minute)
	if err != nil {
		t.Fatalf("NewMinter: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/internal/sync/jwks.json", nil)
	rec := httptest.NewRecorder()

	JWKSHandler(minter)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}

	var jwks jose.JSONWebKeySet
	if err := json.Unmarshal(rec.Body.Bytes(), &jwks); err != nil {
		t.Fatalf("decode JWKS body: %v (body = %s)", err, rec.Body.String())
	}
	if len(jwks.Keys) != 1 {
		t.Fatalf("JWKS keys = %d, want 1", len(jwks.Keys))
	}
	want := minter.JWKS()
	if jwks.Keys[0].KeyID != want.Keys[0].KeyID {
		t.Errorf("kid = %q, want %q", jwks.Keys[0].KeyID, want.Keys[0].KeyID)
	}
	if jwks.Keys[0].Algorithm != string(jose.RS256) {
		t.Errorf("alg = %q, want RS256", jwks.Keys[0].Algorithm)
	}
}
