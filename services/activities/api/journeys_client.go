// Package api (this file) — the cross-service tenancy guard #46 needs before
// activities can accept a client-supplied journey_id. Activities does not
// own the journeys schema (ownership rule 1, docs/architecture/
// service-decomposition.md §4: "cross-context references are by ID, not
// FK") — the activities.activities table's journey_id column (added ahead
// of #46's UI, services/activities/api/write.go's activityCreateRequest doc
// comment) is a soft reference this service has no database access to
// verify directly. The only trustworthy way to know whether a journey_id
// belongs to the caller's organization is to ask the OWNING service
// (journeys), exactly the same zero-trust pattern this service's own
// apiaries_client.go already established for apiary_id.
//
// This closes a real cross-org IDOR gap (#46 review finding): before this
// file, createActivity wrote a client-supplied journey_id with ZERO
// ownership verification — unlike apiary_id, which always goes through
// ApiaryVerifier first. A malicious/buggy caller could otherwise attach an
// activity to any journey_id it can guess/enumerate, including one that
// belongs to a different organization entirely, silently leaking the
// existence and association of a foreign org's journey via a 201 response.
//
// This is a verbatim structural copy of ApiaryVerifier (apiaries_client.go)
// — same behavior, same zero-trust rationale, same "journeys doesn't import
// activities' Go module, activities doesn't import journeys' Go module"
// separate-service/separate-module discipline (service-decomposition.md §4
// rule 2) — targeting the journeys service's own new client-facing,
// org-scoped GET /v1/journeys/{id} (services/journeys/api/write.go's
// getJourney, added by this same story) instead of apiaries' getApiary.
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

// ErrJourneyUnavailable wraps a transport/5xx failure talking to the
// journeys service — distinct from a clean (false, nil) "not this org's
// journey" result, so callers never mistake an upstream outage for a
// legitimate tenancy rejection. Mirrors ErrApiaryUnavailable's own
// distinction.
var ErrJourneyUnavailable = errors.New("activities: journeys service unavailable")

// JourneyVerifier checks journey ownership via the journeys service's own
// client-facing, org-scoped GET /v1/journeys/{id} (services/journeys/api/
// write.go's getJourney) — that handler 404s for a journey that doesn't
// exist OR belongs to a different organization (ADR-0002 scope-hiding),
// which is exactly the "does this id belong to my org" question this
// service needs answered, with no new internal-only endpoint required on
// the journeys side (mirrors ApiaryVerifier's own rationale).
type JourneyVerifier struct {
	journeysURL string
	client      *http.Client
}

// NewJourneyVerifier builds a verifier targeting journeysURL (the
// operator-configured internal base URL, INTERNAL_JOURNEYS_URL — never a
// client-supplied value). A nil client defaults to a 5s-timeout,
// OTel-instrumented client, matching NewApiaryVerifier's own default.
func NewJourneyVerifier(journeysURL string, client *http.Client) (*JourneyVerifier, error) {
	if journeysURL == "" {
		return nil, fmt.Errorf("activities: NewJourneyVerifier requires journeysURL")
	}
	if client == nil {
		client = &http.Client{
			Timeout:   5 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		}
	}
	return &JourneyVerifier{
		// Trim a trailing slash so an operator-supplied URL never produces a
		// double slash when concatenated below (mirrors NewApiaryVerifier).
		journeysURL: strings.TrimRight(journeysURL, "/"),
		client:      client,
	}, nil
}

// BelongsToOrg reports whether journeyID exists and belongs to the caller's
// organization. bearer is the caller's OWN Authorization header, forwarded
// verbatim so journeys re-authenticates and re-derives the org from the SAME
// verified token this service's own requireOrg used (zero-trust, auth.md
// §4) — activities never asserts an org value to journeys out of band. A
// 200 means the id is a live journey in the caller's org; a 404 means "not
// found or not this org's" (indistinguishable by design, ADR-0002) — both
// are ordinary, expected outcomes, not errors. Any other status or a
// transport failure returns ErrJourneyUnavailable so the caller can tell
// "this journey_id is invalid" apart from "we couldn't ask". Mirrors
// ApiaryVerifier.BelongsToOrg exactly.
func (v *JourneyVerifier) BelongsToOrg(ctx context.Context, bearer, journeyID string) (bool, error) {
	reqURL := v.journeysURL + "/v1/journeys/" + url.PathEscape(journeyID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return false, fmt.Errorf("build journeys request: %w", err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := v.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrJourneyUnavailable, err)
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
		return false, fmt.Errorf("%w: journeys responded %d", ErrJourneyUnavailable, resp.StatusCode)
	}
}
