// Package cors provides a controller-agnostic CORS middleware for the shared
// service template. The BeekeepingIT admin app (#72/#73) is served from its own
// origin (admin.beekeepingit.local, ADR-0016/#449) and calls the platform API on
// the app host, so browser fetches are cross-origin: without CORS the preflight
// fails and — critically for optimistic concurrency (FR-TEN-2) — the response's
// ETag header is hidden from JavaScript unless it is explicitly exposed.
//
// Placement rationale: this lives in servicetemplate (not a Traefik-only Ingress
// annotation) so every service inherits identical CORS behavior and the gateway
// stays a plain, swappable networking.k8s.io/v1 Ingress (NFR-ARC-2). Origins are
// configured per environment via CORS_ALLOWED_ORIGINS (config.Config), never
// hardcoded.
package cors

import (
	"net/http"
	"slices"
	"strings"
)

// Config configures the CORS middleware.
type Config struct {
	// AllowedOrigins is the exact-match allowlist of browser origins (scheme +
	// host + optional port, no trailing slash) permitted to make credentialed
	// cross-origin requests. Empty disables CORS entirely (no CORS headers are
	// emitted, so only same-origin callers work) — the safe default for a
	// service with no cross-origin client.
	AllowedOrigins []string
}

// allowedMethods is the set of methods the API exposes to cross-origin callers.
// Kept as a package constant so the preflight response and any future
// same-origin assertions stay in one place. DELETE/PATCH are required for the
// organization edit path (#289, FR-TEN-2); OPTIONS is the preflight itself.
const allowedMethods = "GET, POST, PATCH, PUT, DELETE, OPTIONS"

// allowedHeaders lists the request headers the SPA sends that are not CORS-safe
// by default and therefore must be allowed on preflight: Authorization (bearer
// token, NFR-SEC-1), If-Match (optimistic concurrency, FR-TEN-2) and
// Content-Type (JSON bodies).
const allowedHeaders = "Authorization, If-Match, Content-Type"

// exposedHeaders lists the non-simple response headers a browser must be allowed
// to read on a cross-origin response. ETag is the load-bearing one (#449): the
// admin app reads it from GET /organizations/me and echoes it as If-Match on the
// PATCH; browsers hide it cross-origin unless it is named here.
const exposedHeaders = "ETag"

// preflightMaxAge caps how long a browser may cache a preflight result (seconds).
const preflightMaxAge = "600"

// Middleware returns a net/http middleware that answers CORS preflights and
// annotates cross-origin responses for the configured origins. It is safe to
// mount ahead of authentication: a preflight OPTIONS carries no credentials (the
// browser strips them), so it must be answered without hitting the JWT
// middleware, and this middleware short-circuits it with 204.
//
// When AllowedOrigins is empty the middleware is a transparent pass-through.
func Middleware(cfg Config) func(http.Handler) http.Handler {
	// Copy so a later mutation of the caller's slice can't change behavior.
	allowed := slices.Clone(cfg.AllowedOrigins)

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			origin := r.Header.Get("Origin")

			// Not a cross-origin browser request, or CORS disabled: pass through.
			if origin == "" || len(allowed) == 0 {
				next.ServeHTTP(w, r)
				return
			}

			// Always Vary on Origin once CORS is in play so a cached response for
			// one origin is never served to another (or to a same-origin caller).
			w.Header().Add("Vary", "Origin")

			if !originAllowed(allowed, origin) {
				// Origin not on the allowlist: emit no CORS headers. The browser
				// then blocks the response client-side. A preflight still needs a
				// terminal response, so short-circuit it rather than authenticating.
				if isPreflight(r) {
					w.WriteHeader(http.StatusNoContent)
					return
				}
				next.ServeHTTP(w, r)
				return
			}

			// Allowed origin: echo it (never "*", since credentials are allowed)
			// and advertise what JS may read on the actual response.
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Set("Access-Control-Allow-Credentials", "true")
			h.Set("Access-Control-Expose-Headers", exposedHeaders)

			if isPreflight(r) {
				h.Set("Access-Control-Allow-Methods", allowedMethods)
				h.Set("Access-Control-Allow-Headers", allowedHeaders)
				h.Set("Access-Control-Max-Age", preflightMaxAge)
				w.WriteHeader(http.StatusNoContent)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// isPreflight reports whether r is a CORS preflight: an OPTIONS request carrying
// the Access-Control-Request-Method header the browser adds. A plain OPTIONS
// (no such header) is a real request and must fall through to the handler.
func isPreflight(r *http.Request) bool {
	return r.Method == http.MethodOptions &&
		r.Header.Get("Access-Control-Request-Method") != ""
}

// originAllowed reports whether origin matches an allowlisted origin. An origin
// is scheme://host[:port] with no path/query, and its host is compared
// case-insensitively (RFC 6454); browsers always send a normalized, lowercase
// origin, so the case-insensitive whole-string compare here is a superset of the
// strict rule and never matches anything a browser wouldn't.
func originAllowed(allowed []string, origin string) bool {
	for _, a := range allowed {
		if strings.EqualFold(a, origin) {
			return true
		}
	}
	return false
}
