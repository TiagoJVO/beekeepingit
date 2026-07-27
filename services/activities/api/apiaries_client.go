// Package api (this file) — the cross-service tenancy guard #39 needs before
// it can accept a client-supplied apiary_id. Activities does not own the
// apiaries schema (ownership rule 1,
// docs/architecture/service-decomposition.md §4: "cross-context references
// are by ID, not FK") — the activities.activities table's apiary_id column
// (store/migrations/00001_create_activities.sql) is a soft reference this
// service has no database access to verify directly. The only trustworthy
// way to know whether an apiary_id belongs to the caller's organization is
// to ask the OWNING service, exactly the same zero-trust pattern
// authn.NewOrgResolver already uses for identity/organizations
// (services/servicetemplate/authn/resolver.go) and
// services/organizations/api/organizations.go's HTTPUserResolver use for
// identity.
//
// This is the direct carry-over of #38's review finding (closed for
// apiaries' OWN counter-sync path in #284,
// "fix(apiaries): close cross-tenant IDOR on counter sync") applied to
// activities: without this check, a caller could attach an activity to any
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
// tenancy rejection (mirrors organizations/api/organizations.go's
// identityUnavailable's same distinction for its own upstream call).
var ErrApiaryUnavailable = errors.New("activities: apiaries service unavailable")

// ApiaryVerifier checks apiary ownership via the apiaries service's own
// client-facing, org-scoped GET /v1/apiaries/{id} (services/apiaries/api/
// apiaries.go's getApiary) — that handler already 404s for an apiary that
// doesn't exist OR belongs to a different organization (ADR-0002
// scope-hiding), which is exactly the "does this id belong to my org"
// question this service needs answered, with no new endpoint required on
// the apiaries side.
type ApiaryVerifier struct {
	apiariesURL string
	client      *http.Client
}

// NewApiaryVerifier builds a verifier targeting apiariesURL (the operator-
// configured internal base URL, INTERNAL_APIARIES_URL — never a
// client-supplied value). A nil client defaults to a 5s-timeout, OTel-
// instrumented client, matching authn.NewOrgResolver's own default.
func NewApiaryVerifier(apiariesURL string, client *http.Client) (*ApiaryVerifier, error) {
	if apiariesURL == "" {
		return nil, fmt.Errorf("activities: NewApiaryVerifier requires apiariesURL")
	}
	if client == nil {
		client = &http.Client{
			Timeout:   5 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		}
	}
	return &ApiaryVerifier{
		// Trim a trailing slash so an operator-supplied URL never produces a
		// double slash when concatenated below (mirrors services/sync/api/
		// coordinator.go's NewCoordinator).
		apiariesURL: strings.TrimRight(apiariesURL, "/"),
		client:      client,
	}, nil
}

// BelongsToOrg reports whether apiaryID exists and belongs to the caller's
// organization. bearer is the caller's OWN Authorization header, forwarded
// verbatim so apiaries re-authenticates and re-derives the org from the
// SAME verified token this service's own requireOrg used (zero-trust,
// auth.md §4) — activities never asserts an org value to apiaries out of
// band. A 200 means the id is a live apiary in the caller's org; a 404
// means "not found or not this org's" (indistinguishable by design,
// ADR-0002) — both are ordinary, expected outcomes, not errors. Any other
// status or a transport failure returns ErrApiaryUnavailable so the caller
// can tell "this apiary_id is invalid" apart from "we couldn't ask".
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
