package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNewMemberVerifier_RequiresURL(t *testing.T) {
	if _, err := NewMemberVerifier("", nil); err == nil {
		t.Fatalf("NewMemberVerifier(\"\", nil) succeeded, want an error")
	}
}

const (
	callerOrgID = "b0000000-0000-7000-8000-000000000001"
	otherOrgID  = "b0000000-0000-7000-8000-000000000099"
	assigneeID  = "a0000000-0000-7000-8000-000000000002"
)

func TestMemberVerifier_BelongsToOrg_200SameOrgIsTrue(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.String()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(membershipDTO{OrganizationID: callerOrgID, Role: "admin"})
	}))
	defer srv.Close()

	v, err := NewMemberVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", callerOrgID, assigneeID)
	if err != nil {
		t.Fatalf("BelongsToOrg: %v", err)
	}
	if !belongs {
		t.Fatalf("belongs = false, want true when the assignee's active org matches the caller's own org")
	}
	if gotPath != "/internal/memberships/active?user_id="+assigneeID {
		t.Fatalf("request path = %q, want /internal/memberships/active?user_id=<id>", gotPath)
	}
}

// TestMemberVerifier_BelongsToOrg_200DifferentOrgIsFalse is the CRITICAL
// cross-tenant IDOR case this file exists for: an assignee_id that has an
// ACTIVE membership, but in a DIFFERENT organization than the caller's own,
// must never be accepted.
func TestMemberVerifier_BelongsToOrg_200DifferentOrgIsFalse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(membershipDTO{OrganizationID: otherOrgID, Role: "user"})
	}))
	defer srv.Close()

	v, err := NewMemberVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", callerOrgID, assigneeID)
	if err != nil {
		t.Fatalf("BelongsToOrg: %v", err)
	}
	if belongs {
		t.Fatalf("belongs = true, want false — the assignee belongs to a DIFFERENT organization than the caller's")
	}
}

func TestMemberVerifier_BelongsToOrg_404IsFalseNoError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	v, err := NewMemberVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", callerOrgID, assigneeID)
	if err != nil {
		t.Fatalf("BelongsToOrg: %v, want no error on 404 (no active membership anywhere)", err)
	}
	if belongs {
		t.Fatalf("belongs = true, want false on 404")
	}
}

func TestMemberVerifier_BelongsToOrg_5xxIsUnavailableError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	v, err := NewMemberVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
	}
	belongs, err := v.BelongsToOrg(context.Background(), "Bearer test-token", callerOrgID, assigneeID)
	if err == nil {
		t.Fatalf("BelongsToOrg succeeded on a 5xx upstream response, want ErrMembersUnavailable")
	}
	if belongs {
		t.Fatalf("belongs = true on an errored call, want false")
	}
	if !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("error = %v, want it to reference organizations being unavailable", err)
	}
}

func TestMemberVerifier_BelongsToOrg_ForwardsBearer(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(membershipDTO{OrganizationID: callerOrgID, Role: "admin"})
	}))
	defer srv.Close()

	v, err := NewMemberVerifier(srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
	}
	if _, err := v.BelongsToOrg(context.Background(), "Bearer test-token", callerOrgID, assigneeID); err != nil {
		t.Fatalf("BelongsToOrg: %v", err)
	}
	// The caller's OWN bearer must be forwarded verbatim (zero-trust,
	// auth.md §4) — todos never asserts membership to organizations out of
	// band, it re-authenticates organizations' own way.
	if gotAuth != "Bearer test-token" {
		t.Fatalf("forwarded Authorization = %q, want the caller's own bearer", gotAuth)
	}
}

func TestMemberVerifier_BelongsToOrg_TransportErrorIsUnavailable(t *testing.T) {
	v, err := NewMemberVerifier("http://127.0.0.1:0", nil)
	if err != nil {
		t.Fatalf("NewMemberVerifier: %v", err)
	}
	if _, err := v.BelongsToOrg(context.Background(), "Bearer test-token", callerOrgID, assigneeID); err == nil {
		t.Fatalf("BelongsToOrg against an unreachable host succeeded, want an error")
	}
}
