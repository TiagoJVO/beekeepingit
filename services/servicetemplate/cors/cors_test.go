package cors_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/cors"
)

const adminOrigin = "https://admin.beekeepingit.local:8443"

// etagHandler is a stand-in for a resource-versioned endpoint (e.g.
// GET /organizations/me): it sets an ETag, exactly the header the admin app must
// be able to read cross-origin (#449, FR-TEN-2).
func etagHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("ETag", `"v1"`)
		w.WriteHeader(http.StatusOK)
	})
}

func serve(t *testing.T, cfg cors.Config, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	cors.Middleware(cfg)(etagHandler()).ServeHTTP(rec, req)
	return rec
}

// TestExposesETagForAllowedOrigin is the load-bearing regression test for #449:
// a cross-origin GET from the admin origin must come back with
// Access-Control-Expose-Headers: ETag (and the matching allow-origin), or the
// browser hides the ETag and optimistic concurrency breaks. It FAILS if the
// exposure is dropped.
func TestExposesETagForAllowedOrigin(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/organizations/me", nil)
	req.Header.Set("Origin", adminOrigin)

	rec := serve(t, cors.Config{AllowedOrigins: []string{adminOrigin}}, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != adminOrigin {
		t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, adminOrigin)
	}
	if got := rec.Header().Get("Access-Control-Expose-Headers"); got != "ETag" {
		t.Errorf("Access-Control-Expose-Headers = %q, want %q (browser hides ETag cross-origin without it)", got, "ETag")
	}
	if got := rec.Header().Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Errorf("Access-Control-Allow-Credentials = %q, want \"true\"", got)
	}
	if got := rec.Header().Get("ETag"); got != `"v1"` {
		t.Errorf("ETag = %q, want %q (handler must still run)", got, `"v1"`)
	}
}

// TestPreflightAllowsConcurrencyHeaders asserts the OPTIONS preflight advertises
// the methods and headers the admin edit flow needs (PATCH + If-Match), and is
// answered with 204 without invoking the downstream handler.
func TestPreflightAllowsConcurrencyHeaders(t *testing.T) {
	req := httptest.NewRequest(http.MethodOptions, "/v1/organizations/org-1", nil)
	req.Header.Set("Origin", adminOrigin)
	req.Header.Set("Access-Control-Request-Method", http.MethodPatch)
	req.Header.Set("Access-Control-Request-Headers", "if-match")

	rec := serve(t, cors.Config{AllowedOrigins: []string{adminOrigin}}, req)

	if rec.Code != http.StatusNoContent {
		t.Errorf("preflight status = %d, want %d", rec.Code, http.StatusNoContent)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != adminOrigin {
		t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, adminOrigin)
	}
	for _, method := range []string{"PATCH", "DELETE", "OPTIONS"} {
		if !containsToken(rec.Header().Get("Access-Control-Allow-Methods"), method) {
			t.Errorf("Access-Control-Allow-Methods %q missing %q", rec.Header().Get("Access-Control-Allow-Methods"), method)
		}
	}
	for _, header := range []string{"Authorization", "If-Match", "Content-Type"} {
		if !containsToken(rec.Header().Get("Access-Control-Allow-Headers"), header) {
			t.Errorf("Access-Control-Allow-Headers %q missing %q", rec.Header().Get("Access-Control-Allow-Headers"), header)
		}
	}
	// The handler sets an ETag; a preflight must NOT reach it.
	if rec.Header().Get("ETag") != "" {
		t.Error("preflight reached the downstream handler (ETag set); it must short-circuit")
	}
}

func TestDisallowedOriginGetsNoCORSHeaders(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/organizations/me", nil)
	req.Header.Set("Origin", "https://evil.example")

	rec := serve(t, cors.Config{AllowedOrigins: []string{adminOrigin}}, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want empty for a disallowed origin", got)
	}
	if got := rec.Header().Get("Access-Control-Expose-Headers"); got != "" {
		t.Errorf("Access-Control-Expose-Headers = %q, want empty for a disallowed origin", got)
	}
	// The request itself still succeeds server-side (the browser enforces CORS).
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d (server does not reject; browser blocks)", rec.Code, http.StatusOK)
	}
}

func TestNoOriginIsPassThrough(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/organizations/me", nil)

	rec := serve(t, cors.Config{AllowedOrigins: []string{adminOrigin}}, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want empty for a same-origin request", got)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestEmptyAllowlistDisablesCORS(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/organizations/me", nil)
	req.Header.Set("Origin", adminOrigin)

	rec := serve(t, cors.Config{}, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want empty when CORS is disabled", got)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestAllowedOriginIsCaseInsensitiveOnHost(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/organizations/me", nil)
	req.Header.Set("Origin", "https://ADMIN.beekeepingit.local:8443")

	rec := serve(t, cors.Config{AllowedOrigins: []string{adminOrigin}}, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got == "" {
		t.Error("Access-Control-Allow-Origin empty; host match must be case-insensitive (RFC 6454)")
	}
}

// containsToken reports whether a comma-separated header value contains token
// (case-insensitive, trimming spaces) — how a browser parses these lists.
func containsToken(headerValue, token string) bool {
	for _, part := range splitComma(headerValue) {
		if equalFoldTrim(part, token) {
			return true
		}
	}
	return false
}

func splitComma(s string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return out
}

func equalFoldTrim(a, b string) bool {
	trim := func(s string) string {
		for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
			s = s[1:]
		}
		for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
			s = s[:len(s)-1]
		}
		return s
	}
	a, b = trim(a), trim(b)
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if 'A' <= ca && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if 'A' <= cb && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}
