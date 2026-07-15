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
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
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
		// Trim a trailing slash so an operator-supplied URL (env var, config)
		// never produces a double slash when concatenated with the internal
		// endpoint paths below.
		apiariesURL: strings.TrimRight(apiariesURL, "/"),
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
		slog.ErrorContext(ctx, "sync validate call failed", slog.Any("error", err))
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
		slog.ErrorContext(ctx, "sync apply call failed", slog.Any("error", err))
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

	// Cap the upstream response read symmetrically with the request-side cap
	// (maxBatchBytes) — an owning service is trusted, but not to the point of
	// letting a runaway or misbehaving response exhaust memory here.
	out, err := io.ReadAll(io.LimitReader(resp.Body, maxBatchBytes))
	if err != nil {
		return upstreamResponse{}, err
	}
	return upstreamResponse{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type"), body: out}, nil
}

func badGateway(detail string) upstreamResponse {
	// RFC 9457 problem, built through the shared Problem shape (the shared
	// problem package has no 502 constructor, so it's assembled here rather
	// than hand-rolled as a JSON string). code lets clients branch on
	// "retryable upstream".
	p := problem.Problem{
		Title:  "Bad Gateway",
		Status: http.StatusBadGateway,
		Detail: detail,
		Code:   "sync.upstream_unavailable",
	}
	body, err := json.Marshal(p)
	if err != nil {
		// Marshaling a static struct of plain strings/ints cannot fail in
		// practice; fall back to a minimal, still-valid problem+json body
		// rather than panicking or losing the 502 semantics.
		slog.Error("marshal bad gateway problem", slog.Any("error", err))
		body = []byte(`{"title":"Bad Gateway","status":502,"code":"sync.upstream_unavailable"}`)
	}
	return upstreamResponse{status: http.StatusBadGateway, contentType: "application/problem+json", body: body}
}
