// Package api (this file) — the cross-service tenancy guard #51 needs before
// it can accept a client-supplied apiary_id. Todos does not own the apiaries
// schema (ownership rule 1, docs/architecture/service-decomposition.md §4:
// "cross-context references are by ID, not FK") — the todos.todos table's
// apiary_id column (store/migrations/00003_add_apiary_id.sql) is a soft
// reference this service has no database access to verify directly. The only
// trustworthy way to know whether an apiary_id belongs to the caller's
// organization is to ask the OWNING service, exactly the same zero-trust
// pattern api/members_client.go already uses for assignee_id (against
// organizations) and activities/api/apiaries_client.go uses for its own
// apiary_id (against apiaries) — this file is a verbatim structural copy of
// that one, ported to this package.
//
// This is the direct carry-over of #38's review finding (closed for
// apiaries' OWN counter-sync path in #284,
// "fix(apiaries): close cross-tenant IDOR on counter sync") applied to
// todos: without this check, a caller could associate a todo with any
// apiary_id it can guess/enumerate, including one that belongs to a
// different organization entirely.
package api

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// ErrApiaryUnavailable wraps a transport/5xx failure talking to the apiaries
// service — distinct from a clean (false, nil) "not this org's apiary"
// result, so callers never mistake an upstream outage for a legitimate
// tenancy rejection (mirrors activities/api/apiaries_client.go's
// ErrApiaryUnavailable's same distinction).
var ErrApiaryUnavailable = errors.New("todos: apiaries service unavailable")

// ApiaryVerifier checks apiary ownership via the apiaries service's own
// client-facing, org-scoped GET /v1/apiaries/{id} (services/apiaries/api/
// apiaries.go's getApiary) — that handler already 404s for an apiary that
// doesn't exist OR belongs to a different organization (ADR-0002
// scope-hiding), which is exactly the "does this id belong to my org"
// question this service needs answered, with no new endpoint required on
// the apiaries side. Mirrors activities/api/apiaries_client.go's
// ApiaryVerifier exactly.
type ApiaryVerifier struct {
	apiariesURL string
	client      *http.Client
}

// NewApiaryVerifier builds a verifier targeting apiariesURL (the operator-
// configured internal base URL, INTERNAL_APIARIES_URL — never a
// client-supplied value). A nil client defaults to a 5s-timeout, OTel-
// instrumented client, matching NewMemberVerifier's own default.
func NewApiaryVerifier(apiariesURL string, client *http.Client) (*ApiaryVerifier, error) {
	if apiariesURL == "" {
		return nil, fmt.Errorf("todos: NewApiaryVerifier requires apiariesURL")
	}
	if client == nil {
		client = &http.Client{
			Timeout:   5 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		}
	}
	return &ApiaryVerifier{
		// Trim a trailing slash so an operator-supplied URL never produces a
		// double slash when concatenated below (mirrors NewMemberVerifier /
		// services/sync/api/coordinator.go's NewCoordinator).
		apiariesURL: strings.TrimRight(apiariesURL, "/"),
		client:      client,
	}, nil
}

// BelongsToOrg reports whether apiaryID exists and belongs to the caller's
// organization. bearer is the caller's OWN Authorization header, forwarded
// verbatim so apiaries re-authenticates and re-derives the org from the SAME
// verified token this service's own requireOrg used (zero-trust, auth.md
// §4) — todos never asserts an org value to apiaries out of band. A 200
// means the id is a live apiary in the caller's org; a 404 means "not found
// or not this org's" (indistinguishable by design, ADR-0002) — both are
// ordinary, expected outcomes, not errors. Any other status or a transport
// failure returns ErrApiaryUnavailable so the caller can tell "this
// apiary_id is invalid" apart from "we couldn't ask".
func (v *ApiaryVerifier) BelongsToOrg(ctx context.Context, bearer, apiaryID string) (bool, error) {
	reqURL := v.apiariesURL + "/v1/apiaries/" + url.PathEscape(apiaryID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return false, fmt.Errorf("build apiaries request: %w", err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := v.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrApiaryUnavailable, err)
	}
	defer resp.Body.Close()
	// Drain (not decode — the response body is never consulted, only the
	// status code) so the connection can be reused, capped defensively
	// against a misbehaving upstream.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))

	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound:
		return false, nil
	default:
		return false, fmt.Errorf("%w: apiaries responded %d", ErrApiaryUnavailable, resp.StatusCode)
	}
}
