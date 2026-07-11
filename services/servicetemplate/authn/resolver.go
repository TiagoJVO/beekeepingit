package authn

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// ResolveConfig configures the org-resolution middleware (NewOrgResolver).
type ResolveConfig struct {
	// IdentityBaseURL is the identity service's in-cluster base URL, e.g.
	// "http://identity:8080". Its GET /internal/users/by-sub/{sub} maps an
	// OIDC subject to a user.
	IdentityBaseURL string
	// OrganizationsBaseURL is the organizations service's in-cluster base
	// URL. Its GET /internal/memberships/active?user_id= maps a user to its
	// active membership (organization_id + role).
	OrganizationsBaseURL string
	// CacheTTL bounds how long a resolved (sub → user → org+role) result is
	// reused per instance. Defaults to 60s when zero (§4.2).
	CacheTTL time.Duration
	// HTTPClient is the client used for the internal calls. When nil, a
	// client with a 5s timeout and OTel transport (W3C traceparent
	// propagation, §5.3) is used.
	HTTPClient *http.Client
}

// NewOrgResolver builds middleware that resolves the request's org-scoped
// authorization and enriches the Claims in context with UserID,
// OrganizationID and Role (auth.md §5.1, walking-skeleton.md §4.2). It MUST be
// layered on top of NewMiddleware's output — it reads the authenticated
// Claims (Sub) that middleware stored.
//
// Resolution makes two internal REST calls (identity, then organizations),
// forwarding the caller's bearer token so each owning service re-authenticates
// and re-scopes (zero-trust, auth.md §4). Results are cached per instance for
// CacheTTL, keyed by sub. A verified caller with no known user or no active
// membership gets 403 (authenticated but not authorized for any org).
func NewOrgResolver(cfg ResolveConfig) (func(http.Handler) http.Handler, error) {
	if cfg.IdentityBaseURL == "" || cfg.OrganizationsBaseURL == "" {
		return nil, fmt.Errorf("authn: NewOrgResolver requires IdentityBaseURL and OrganizationsBaseURL")
	}
	ttl := cfg.CacheTTL
	if ttl <= 0 {
		ttl = 60 * time.Second
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{
			Timeout:   5 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		}
	}

	r := &resolver{
		identityURL:      cfg.IdentityBaseURL,
		organizationsURL: cfg.OrganizationsBaseURL,
		ttl:              ttl,
		client:           client,
		cache:            map[string]cacheEntry{},
		now:              time.Now,
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			claims, ok := FromContext(req.Context())
			if !ok {
				// Programming error: the resolver was mounted without the
				// authn middleware in front of it.
				problem.Write(w, req, problem.Internal())
				return
			}

			enriched, prob := r.resolve(req.Context(), claims, req.Header.Get("Authorization"))
			if prob != nil {
				// AC (#28): a denial here — no known user, or no active org
				// membership — is logged, not just returned to the caller.
				// sub is a verified JWT claim (safe to log, not
				// client-controlled free text); no token/bearer material is
				// ever logged. A transient upstream failure (500, e.g.
				// identity/organizations unreachable) is logged too, but
				// distinguished from a genuine denial so on-call doesn't
				// mistake infra flakiness for an authz event.
				msg := "authz denied: org resolution failed"
				if prob.Status >= 500 {
					msg = "org resolution failed: upstream error"
				}
				logging.FromContext(req.Context()).WarnContext(req.Context(), msg,
					slog.String("sub", claims.Sub),
					slog.Int("status", prob.Status),
					slog.String("detail", prob.Detail),
				)
				problem.Write(w, req, *prob)
				return
			}

			ctx := context.WithValue(req.Context(), claimsKey{}, enriched)
			next.ServeHTTP(w, req.WithContext(ctx))
		})
	}, nil
}

type cacheEntry struct {
	userID    string
	orgID     string
	role      string
	expiresAt time.Time
}

type resolver struct {
	identityURL      string
	organizationsURL string
	ttl              time.Duration
	client           *http.Client
	now              func() time.Time

	mu    sync.Mutex
	cache map[string]cacheEntry
}

func (r *resolver) resolve(ctx context.Context, claims Claims, bearer string) (Claims, *problem.Problem) {
	if e, ok := r.get(claims.Sub); ok {
		claims.UserID, claims.OrganizationID, claims.Role = e.userID, e.orgID, e.role
		return claims, nil
	}

	userID, prob := r.resolveUser(ctx, bearer, claims.Sub)
	if prob != nil {
		return claims, prob
	}
	orgID, role, prob := r.resolveMembership(ctx, bearer, userID)
	if prob != nil {
		return claims, prob
	}

	r.set(claims.Sub, cacheEntry{userID: userID, orgID: orgID, role: role, expiresAt: r.now().Add(r.ttl)})
	claims.UserID, claims.OrganizationID, claims.Role = userID, orgID, role
	return claims, nil
}

func (r *resolver) get(sub string) (cacheEntry, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.cache[sub]
	if !ok {
		return cacheEntry{}, false
	}
	if !r.now().Before(e.expiresAt) {
		delete(r.cache, sub)
		return cacheEntry{}, false
	}
	return e, true
}

func (r *resolver) set(sub string, e cacheEntry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cache[sub] = e
}

type userDTO struct {
	UserID string `json:"user_id"`
}

type membershipDTO struct {
	OrganizationID string `json:"organization_id"`
	Role           string `json:"role"`
}

func (r *resolver) resolveUser(ctx context.Context, bearer, sub string) (string, *problem.Problem) {
	u := r.identityURL + "/internal/users/by-sub/" + url.PathEscape(sub)
	var out userDTO
	status, err := r.getJSON(ctx, u, bearer, &out)
	if err != nil {
		return "", ptr(problem.Internal())
	}
	switch status {
	case http.StatusOK:
		return out.UserID, nil
	case http.StatusNotFound:
		return "", ptr(problem.Forbidden("caller is not a known user"))
	default:
		return "", ptr(problem.Internal())
	}
}

func (r *resolver) resolveMembership(ctx context.Context, bearer, userID string) (string, string, *problem.Problem) {
	u := r.organizationsURL + "/internal/memberships/active?user_id=" + url.QueryEscape(userID)
	var out membershipDTO
	status, err := r.getJSON(ctx, u, bearer, &out)
	if err != nil {
		return "", "", ptr(problem.Internal())
	}
	switch status {
	case http.StatusOK:
		return out.OrganizationID, out.Role, nil
	case http.StatusNotFound:
		return "", "", ptr(problem.Forbidden("caller has no active organization membership"))
	default:
		return "", "", ptr(problem.Internal())
	}
}

// getJSON issues an authenticated GET, decoding a 2xx body into out. It
// returns the HTTP status so the caller can distinguish 404 (→ 403) from
// transient failures (→ 500).
func (r *resolver) getJSON(ctx context.Context, rawURL, bearer string, out any) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return 0, err
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := r.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}

func ptr(p problem.Problem) *problem.Problem { return &p }
