package authn_test

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
)

// withClaims stands in for NewMiddleware + NewOrgResolver, injecting a known,
// already-resolved Claims directly — RequireRole/RequireOrgPath only ever
// read the resolved Claims, never a token, so this is the right unit-test
// boundary (mirrors apiaries' own injectClaims test fixture).
func withClaims(claims authn.Claims) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			next.ServeHTTP(w, r.WithContext(authn.ContextWithClaims(r.Context(), claims)))
		})
	}
}

// withRequestLogger wraps the chain with a request-scoped logger writing to
// buf, so tests can assert a denial was actually logged (#28 AC).
func withRequestLogger(buf *bytes.Buffer) func(http.Handler) http.Handler {
	logger := slog.New(slog.NewJSONHandler(buf, nil))
	return logging.RequestLogger(logger)
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
}

func TestRequireRole_AllowsListedRole(t *testing.T) {
	var buf bytes.Buffer
	claims := authn.Claims{Sub: "sub-1", UserID: "user-1", OrganizationID: "org-1", Role: "admin"}
	chain := func(next http.Handler) http.Handler {
		return withRequestLogger(&buf)(withClaims(claims)(authn.RequireRole("admin", "user")(next)))
	}

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/organizations/org-1/members", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(buf.String(), "authz denied") {
		t.Errorf("unexpected denial logged for an allowed role: %s", buf.String())
	}
}

func TestRequireRole_RejectsNonAdmin_403AndLogs(t *testing.T) {
	var buf bytes.Buffer
	claims := authn.Claims{Sub: "sub-2", UserID: "user-2", OrganizationID: "org-2", Role: "user"}
	chain := func(next http.Handler) http.Handler {
		return withRequestLogger(&buf)(withClaims(claims)(authn.RequireRole("admin")(next)))
	}

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/organizations/org-2/invitations", nil))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want application/problem+json", ct)
	}
	logged := buf.String()
	if !strings.Contains(logged, "authz denied") {
		t.Errorf("want denial logged, got: %s", logged)
	}
	if !strings.Contains(logged, "\"role\":\"user\"") {
		t.Errorf("want denied role logged, got: %s", logged)
	}
}

func TestRequireRole_MissingClaims_Returns500(t *testing.T) {
	// No withClaims in the chain at all: RequireRole mounted without
	// NewMiddleware/NewOrgResolver in front of it is a wiring bug and must
	// fail closed (500), never silently admit the caller.
	chain := authn.RequireRole("admin")

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/whatever", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500, body = %s", rec.Code, rec.Body.String())
	}
}

func TestRequireRole_UnresolvedRole_Returns500(t *testing.T) {
	// Claims present (authn.NewMiddleware ran) but Role empty (NewOrgResolver
	// didn't run) — also a wiring bug, not a legitimate "no role" caller.
	claims := authn.Claims{Sub: "sub-3"}
	chain := func(next http.Handler) http.Handler { return withClaims(claims)(authn.RequireRole("admin")(next)) }

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/whatever", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500, body = %s", rec.Code, rec.Body.String())
	}
}

// chiStyleParam is a tiny stand-in for chi.URLParam so this test doesn't need
// a real chi router — RequireOrgPath takes the lookup func as a parameter
// precisely to avoid a chi dependency in this package.
func chiStyleParam(value string) func(*http.Request, string) string {
	return func(*http.Request, string) string { return value }
}

func TestRequireOrgPath_MatchingOrg_Allows(t *testing.T) {
	claims := authn.Claims{Sub: "sub-4", OrganizationID: "b0000000-0000-7000-8000-00000000000a"}
	chain := func(next http.Handler) http.Handler {
		return withClaims(claims)(authn.RequireOrgPath("orgId", chiStyleParam("b0000000-0000-7000-8000-00000000000a"))(next))
	}

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/organizations/b0000000-0000-7000-8000-00000000000a", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
}

// TestRequireOrgPath_DifferentOrg_Returns404NotForbidden is the cross-org
// denial case #28's AC calls out explicitly: a caller whose path org differs
// from their own resolved org gets 404 (scope-hiding, ADR-0002), not 403 — and
// the denial is still logged.
func TestRequireOrgPath_DifferentOrg_Returns404NotForbidden(t *testing.T) {
	var buf bytes.Buffer
	claims := authn.Claims{Sub: "sub-5", OrganizationID: "b0000000-0000-7000-8000-00000000000a"}
	otherOrg := "c0000000-0000-7000-8000-00000000000b"
	chain := func(next http.Handler) http.Handler {
		return withRequestLogger(&buf)(withClaims(claims)(authn.RequireOrgPath("orgId", chiStyleParam(otherOrg))(next)))
	}

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/organizations/"+otherOrg, nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(buf.String(), "authz denied") {
		t.Errorf("want cross-org denial logged, got: %s", buf.String())
	}
}

func TestRequireOrgPath_MalformedPathOrgID_Returns404(t *testing.T) {
	claims := authn.Claims{Sub: "sub-6", OrganizationID: "b0000000-0000-7000-8000-00000000000a"}
	chain := func(next http.Handler) http.Handler {
		return withClaims(claims)(authn.RequireOrgPath("orgId", chiStyleParam("not-a-uuid"))(next))
	}

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/organizations/not-a-uuid", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

func TestRequireOrgPath_MissingClaims_Returns500(t *testing.T) {
	chain := authn.RequireOrgPath("orgId", chiStyleParam("b0000000-0000-7000-8000-00000000000a"))

	rec := httptest.NewRecorder()
	chain(okHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/organizations/whatever", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500, body = %s", rec.Code, rec.Body.String())
	}
}

// TestOrgResolver_Denial_IsLogged proves NewOrgResolver's own denial logging
// (resolver.go) — a caller with no active membership is 403'd AND the
// denial is logged, matching RequireRole/RequireOrgPath's contract so the
// whole authz surface is uniformly auditable (#28 AC).
func TestOrgResolver_Denial_IsLogged(t *testing.T) {
	idp := newTestIDP(t)
	priv, pub := generateKey(t, "key-1")
	idp.addKey(pub)
	authnMW := newMiddleware(t, idp.srv.URL)

	stubs := newStubResolveServers(t, http.StatusOK, http.StatusNotFound) // no active membership
	resolveMW, err := authn.NewOrgResolver(authn.ResolveConfig{
		IdentityBaseURL:      stubs.identity.URL,
		OrganizationsBaseURL: stubs.organizations.URL,
	})
	if err != nil {
		t.Fatalf("NewOrgResolver: %v", err)
	}

	var buf bytes.Buffer
	chain := func(next http.Handler) http.Handler {
		return withRequestLogger(&buf)(authnMW(resolveMW(next)))
	}
	token := mintToken(t, priv, "key-1", idp.srv.URL, time.Now().Add(time.Hour), nil)

	rec := doRequest(chain, protectedHandler(new(authn.Claims)), "Bearer "+token)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(buf.String(), "authz denied") {
		t.Errorf("want org-resolution denial logged, got: %s", buf.String())
	}
}
