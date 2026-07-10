package api

import (
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/sync/token"
)

const maxBatchBytes = 1 << 20 // 1 MiB cap on a client transaction

// SyncTokenResponse is the GET /v1/sync/token body.
type SyncTokenResponse struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

// TokenHandler mints a short-lived, org-scoped sync token for the caller.
// Mount behind OIDC authn + the org-resolver so Claims carry sub + org.
func TokenHandler(minter *token.Minter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := authn.FromContext(r.Context())
		if !ok || claims.OrganizationID == "" {
			problem.Write(w, r, problem.Internal())
			return
		}
		raw, exp, err := minter.Mint(claims.Sub, claims.OrganizationID)
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(SyncTokenResponse{Token: raw, ExpiresAt: exp})
	}
}

// JWKSHandler serves the public key set PowerSync validates sync tokens
// against. Unauthenticated (a public key set); internal, never via the gateway.
func JWKSHandler(minter *token.Minter) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(minter.JWKS())
	}
}

// BatchHandler is the single write-back seam: it forwards the caller's whole
// client transaction (and bearer) through the coordinator. Mount behind
// OIDC authn + the org-resolver.
func BatchHandler(coord *Coordinator) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Fail fast on an unauthenticated/unresolved caller; the owning
		// service re-checks the forwarded bearer regardless (zero-trust).
		if claims, ok := authn.FromContext(r.Context()); !ok || claims.OrganizationID == "" {
			problem.Write(w, r, problem.Internal())
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBatchBytes))
		if err != nil {
			problem.Write(w, r, problem.ValidationFailed("could not read request body"))
			return
		}

		resp := coord.handle(r.Context(), r.Header.Get("Authorization"), body)
		ct := resp.contentType
		if ct == "" {
			ct = "application/json"
		}
		w.Header().Set("Content-Type", ct)
		w.WriteHeader(resp.status)
		_, _ = w.Write(resp.body)
	}
}
