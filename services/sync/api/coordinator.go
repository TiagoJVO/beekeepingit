// Package api holds the sync service's HTTP surface: the client-facing
// sync-token + write-back endpoints and the internal JWKS. The write-back
// coordinator (walking-skeleton.md §4.3, sync.md §6) owns no domain data and
// holds no schema credentials — it only orchestrates calls to owning services'
// internal validate/apply endpoints, forwarding the caller's bearer so each
// re-authenticates and re-scopes (zero-trust).
package api

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// Coordinator fans a client transaction out to owning services. In the
// skeleton there is exactly one owning service (apiaries), but the two-phase
// validate-all-then-apply contract is implemented as specified so adding a
// second service later changes nothing here (sync.md §6.3).
type Coordinator struct {
	apiariesURL string
	client      *http.Client
}

// NewCoordinator builds a Coordinator targeting the apiaries service.
func NewCoordinator(apiariesURL string) (*Coordinator, error) {
	if apiariesURL == "" {
		return nil, fmt.Errorf("sync: NewCoordinator requires apiariesURL")
	}
	return &Coordinator{
		apiariesURL: apiariesURL,
		client: &http.Client{
			Timeout:   10 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		},
	}, nil
}

// upstreamResponse is a captured HTTP response from an owning service.
type upstreamResponse struct {
	status      int
	contentType string
	body        []byte
}

// handle runs validate-all then apply for the whole batch (sync.md §6.2),
// forwarding bearer. It returns the response to relay to the client:
//   - validate rejects (422)      → relay that problem+json; nothing applied.
//   - validate/apply unavailable  → 502; the batch stays queued and retries.
//   - apply succeeds              → relay the per-op results.
func (c *Coordinator) handle(ctx context.Context, bearer string, body []byte) upstreamResponse {
	validate, err := c.post(ctx, c.apiariesURL+"/internal/sync/validate", bearer, body)
	if err != nil {
		return badGateway("sync validation is unavailable")
	}
	switch validate.status {
	case http.StatusOK:
		// proceed to apply
	case http.StatusUnprocessableEntity:
		return validate // relay the field-level rejection; nothing written (§6.2)
	default:
		return badGateway("sync validation failed")
	}

	apply, err := c.post(ctx, c.apiariesURL+"/internal/sync/apply", bearer, body)
	if err != nil {
		return badGateway("sync apply is unavailable")
	}
	if apply.status != http.StatusOK {
		// A post-validation failure is transient by construction (§6.2); the
		// idempotent batch heals on PowerSync's forward-retry.
		return badGateway("sync apply failed; retry")
	}
	return apply
}

func (c *Coordinator) post(ctx context.Context, url, bearer string, body []byte) (upstreamResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return upstreamResponse{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return upstreamResponse{}, err
	}
	defer resp.Body.Close()

	out, err := io.ReadAll(resp.Body)
	if err != nil {
		return upstreamResponse{}, err
	}
	return upstreamResponse{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type"), body: out}, nil
}

func badGateway(detail string) upstreamResponse {
	// RFC 9457 problem, hand-built (the shared problem package has no 502
	// constructor). code lets clients branch on "retryable upstream".
	body := fmt.Sprintf(
		`{"title":"Bad Gateway","status":502,"detail":%q,"code":"sync.upstream_unavailable"}`,
		detail,
	)
	return upstreamResponse{status: http.StatusBadGateway, contentType: "application/problem+json", body: []byte(body)}
}
