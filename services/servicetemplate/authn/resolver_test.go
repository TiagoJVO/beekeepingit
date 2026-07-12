package authn_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
)

// stubResolveServers stands in for the identity + organizations services,
// counting hits and asserting the caller's bearer is forwarded (zero-trust).
type stubResolveServers struct {
	identity      *httptest.Server
	organizations *httptest.Server
	idHits        int32
	orgHits       int32
}

func newStubResolveServers(t *testing.T, identityStatus, orgStatus int) *stubResolveServers {
	s := &stubResolveServers{}

	s.identity = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&s.idHits, 1)
		if r.Header.Get("Authorization") == "" {
			t.Errorf("identity: bearer not forwarded")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if identityStatus != http.StatusOK {
			w.WriteHeader(identityStatus)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"user_id": "user-uuid-1"})
	}))
	t.Cleanup(s.identity.Close)

	s.organizations = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&s.orgHits, 1)
		if r.Header.Get("Authorization") == "" {
			t.Errorf("organizations: bearer not forwarded")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if orgStatus != http.StatusOK {
			w.WriteHeader(orgStatus)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"organization_id": "org-uuid-1", "role": "admin"})
	}))
	t.Cleanup(s.organizations.Close)

	return s
}

func TestOrgResolver_EnrichesClaimsAndCaches(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	authnMW := newMiddleware(t, idp.srv.URL)

	stubs := newStubResolveServers(t, http.StatusOK, http.StatusOK)
	resolveMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      stubs.identity.URL,
		OrganizationsBaseURL: stubs.organizations.URL,
	})
	if err != nil {
		t.Fatalf("NewOrgResolver: %v", err)
	}

	var claims authn.Claims
	chain := func(next http.Handler) http.Handler { return authnMW(resolveMW(next)) }
	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), nil)

	rec := doRequest(chain, protectedHandler(&claims), "Bearer "+token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body = %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if claims.UserID != "user-uuid-1" || claims.OrganizationID != "org-uuid-1" || claims.Role != "admin" {
		t.Errorf("enriched claims = %+v, want user-uuid-1/org-uuid-1/admin", claims)
	}

	// A second request for the same sub is served from cache — no extra
	// upstream calls.
	if rec := doRequest(chain, protectedHandler(&claims), "Bearer "+token); rec.Code != http.StatusOK {
		t.Fatalf("second request status = %d, want %d", rec.Code, http.StatusOK)
	}
	if got := atomic.LoadInt32(&stubs.idHits); got != 1 {
		t.Errorf("identity hits = %d, want 1 (second resolve should be cached)", got)
	}
	if got := atomic.LoadInt32(&stubs.orgHits); got != 1 {
		t.Errorf("organizations hits = %d, want 1 (second resolve should be cached)", got)
	}
}

// TestOrgResolver_MembershipChange_ReflectedAfterCacheExpiry is #57's AC
// "changing organization membership updates what replicates to a device on
// the next sync": org resolution is never a one-time/cached-forever claim —
// it re-resolves from the organizations service's live membership lookup
// once the per-instance cache entry (§4.2, default 60s, here set to ~0 so
// the test needs no sleep/clock injection) expires. This proves the seam
// sync.md §3.4 relies on ("a member removed from an org stops getting a
// fresh sync token within one TTL") actually reflects a *changed* org, not
// just that the cache eventually re-fires the same value.
func TestOrgResolver_MembershipChange_ReflectedAfterCacheExpiry(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	authnMW := newMiddleware(t, idp.srv.URL)

	// organizations reports org-A first, then org-B once the caller's active
	// membership changes (e.g. removed from org A, added to org B).
	var mu sync.Mutex
	currentOrg := "org-A-uuid"
	identity := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"user_id": "user-uuid-1"})
	}))
	t.Cleanup(identity.Close)
	organizations := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		org := currentOrg
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]string{"organization_id": org, "role": "admin"})
	}))
	t.Cleanup(organizations.Close)

	// A near-zero TTL means every resolve is effectively a fresh lookup —
	// standing in for "the cache entry has expired" without needing to
	// inject/advance a clock (the package-internal now field isn't reachable
	// from this external test package).
	resolveMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      identity.URL,
		OrganizationsBaseURL: organizations.URL,
		CacheTTL:             time.Nanosecond,
	})
	if err != nil {
		t.Fatalf("NewOrgResolver: %v", err)
	}

	chain := func(next http.Handler) http.Handler { return authnMW(resolveMW(next)) }
	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), nil)

	var claims authn.Claims
	if rec := doRequest(chain, protectedHandler(&claims), "Bearer "+token); rec.Code != http.StatusOK {
		t.Fatalf("first resolve status = %d, want 200", rec.Code)
	}
	if claims.OrganizationID != "org-A-uuid" {
		t.Fatalf("first resolve org = %q, want org-A-uuid", claims.OrganizationID)
	}

	// Membership changes: the caller is now in org B.
	mu.Lock()
	currentOrg = "org-B-uuid"
	mu.Unlock()

	// Give the near-zero TTL entry time to be past expiry, then resolve
	// again — the cache must not serve the stale org-A value.
	time.Sleep(time.Millisecond)
	claims = authn.Claims{}
	if rec := doRequest(chain, protectedHandler(&claims), "Bearer "+token); rec.Code != http.StatusOK {
		t.Fatalf("second resolve status = %d, want 200", rec.Code)
	}
	if claims.OrganizationID != "org-B-uuid" {
		t.Errorf("second resolve org = %q, want org-B-uuid (membership change must be reflected once the cache entry expires)", claims.OrganizationID)
	}
}

func TestOrgResolver_UnknownUser_Forbidden(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	authnMW := newMiddleware(t, idp.srv.URL)

	stubs := newStubResolveServers(t, http.StatusNotFound, http.StatusOK)
	resolveMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      stubs.identity.URL,
		OrganizationsBaseURL: stubs.organizations.URL,
	})
	if err != nil {
		t.Fatalf("NewOrgResolver: %v", err)
	}

	chain := func(next http.Handler) http.Handler { return authnMW(resolveMW(next)) }
	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), nil)

	rec := doRequest(chain, protectedHandler(new(authn.Claims)), "Bearer "+token)
	if rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusForbidden)
	}
	// organizations is never consulted when the user is unknown.
	if got := atomic.LoadInt32(&stubs.orgHits); got != 0 {
		t.Errorf("organizations hits = %d, want 0", got)
	}
}

func TestOrgResolver_NoActiveMembership_Forbidden(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	authnMW := newMiddleware(t, idp.srv.URL)

	stubs := newStubResolveServers(t, http.StatusOK, http.StatusNotFound)
	resolveMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      stubs.identity.URL,
		OrganizationsBaseURL: stubs.organizations.URL,
	})
	if err != nil {
		t.Fatalf("NewOrgResolver: %v", err)
	}

	chain := func(next http.Handler) http.Handler { return authnMW(resolveMW(next)) }
	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), nil)

	rec := doRequest(chain, protectedHandler(new(authn.Claims)), "Bearer "+token)
	if rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusForbidden)
	}
}

func TestNewOrgResolver_RequiresBaseURLs(t *testing.T) {
	if _, err := authn.NewOrgResolver(authn.ResolveConfig{}); err == nil {
		t.Error("want error when base URLs are empty")
	}
}
