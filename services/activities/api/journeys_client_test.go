package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNewJourneyVerifier_RequiresURL(t *testing.T) {
	if _, err := NewJourneyVerifier("", nil); err == nil {
		t.Fatalf("NewJourneyVerifier(\"\", nil) succeeded, want an error")
	}
}

func TestJourneyVerifier_BelongsToOrg_200IsTrue(t *testing.T) {
	var gotPath, gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	v, err := NewJourneyVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewJourneyVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", "11111111-1111-1111-1111-111111111111")
	if err != nil {
		t.Fatalf("BelongsToOrg: %v", err)
	}
	if !belongs {
		t.Fatalf("belongs = false, want true on 200")
	}
	if gotPath != "/v1/journeys/11111111-1111-1111-1111-111111111111" {
		t.Fatalf("request path = %q, want /v1/journeys/<id>", gotPath)
	}
	// The caller's OWN bearer must be forwarded verbatim (zero-trust,
	// auth.md §4) — activities never asserts org membership to journeys out
	// of band, it re-authenticates journeys' own way.
	if gotAuth != "Bearer test-token" {
		t.Fatalf("forwarded Authorization = %q, want the caller's own bearer", gotAuth)
	}
}

// TestJourneyVerifier_BelongsToOrg_404IsFalse is the CRITICAL cross-tenant
// case this file exists for (#46, closing the IDOR gap where journey_id was
// previously written with zero ownership verification): journeys' own GET
// /v1/journeys/{id} 404s for an id that doesn't exist OR belongs to a
// different organization (ADR-0002 scope-hiding), which must be treated as
// "reject this write", never as "allow it".
func TestJourneyVerifier_BelongsToOrg_404IsFalse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	v, err := NewJourneyVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewJourneyVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", "22222222-2222-2222-2222-222222222222")
	if err != nil {
		t.Fatalf("BelongsToOrg: %v", err)
	}
	if belongs {
		t.Fatalf("belongs = true, want false on 404 (cross-org or unknown journey_id)")
	}
}

func TestJourneyVerifier_BelongsToOrg_5xxIsUnavailableError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	v, err := NewJourneyVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewJourneyVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", "33333333-3333-3333-3333-333333333333")
	if err == nil {
		t.Fatalf("BelongsToOrg succeeded on a 5xx upstream response, want ErrJourneyUnavailable")
	}
	if belongs {
		t.Fatalf("belongs = true on an errored call, want false")
	}
	if !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("error = %v, want it to reference journeys being unavailable", err)
	}
}

func TestJourneyVerifier_BelongsToOrg_TransportFailureIsUnavailableError(t *testing.T) {
	v, err := NewJourneyVerifier("http://127.0.0.1:0", nil)
	if err != nil {
		t.Fatalf("NewJourneyVerifier: %v", err)
	}
	if _, err := v.BelongsToOrg(context.Background(), "Bearer test-token", "44444444-4444-4444-4444-444444444444"); err == nil {
		t.Fatalf("BelongsToOrg against an unreachable host succeeded, want an error")
	}
}
