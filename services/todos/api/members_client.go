// Package api (this file) — the cross-service tenancy guard #50 needs before
// it can accept a client-supplied assignee_id. Todos does not own the
// organizations schema (ownership rule 1,
// docs/architecture/service-decomposition.md §4: "cross-context references
// are by ID, not FK") — todos.todos' assignee_id column
// (store/migrations/00001_create_todos.sql) is a soft reference this service
// has no database access to verify directly. The only trustworthy way to know
// whether an assignee_id is a member of the caller's organization is to ask
// the OWNING service — the SAME internal endpoint
// (GET /internal/memberships/active?user_id=<uid>) services/servicetemplate/
// authn/resolver.go's NewOrgResolver already calls (as resolveMembership) to
// resolve the CALLER's own org, so no new endpoint is needed on organizations.
//
// This is the direct carry-over of the CRITICAL cross-tenant IDOR guard
// activities/api/apiaries_client.go already established for apiary_id (itself
// a carry-over of #284's "fix(apiaries): close cross-tenant IDOR on counter
// sync"): without this check, a caller could assign a todo to any user id it
// can guess/enumerate, including one that belongs to a different organization
// entirely, or one with no active membership anywhere.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// ErrMembersUnavailable wraps a transport/5xx failure talking to the
// organizations service — distinct from a clean (false, nil) "not a member of
// this org" result, so callers never mistake an upstream outage for a
// legitimate tenancy rejection (mirrors activities/api/apiaries_client.go's
// ErrApiaryUnavailable's same distinction).
var ErrMembersUnavailable = errors.New("todos: organizations service unavailable")

// membershipDTO mirrors services/organizations/api/memberships.go's
// MembershipResponse / services/servicetemplate/authn/resolver.go's
// membershipDTO — the {"organization_id", "role"} body
// GET /internal/memberships/active returns for a 200.
type membershipDTO struct {
	OrganizationID string `json:"organization_id"`
	Role           string `json:"role"`
}

// MemberVerifier checks assignee ownership via organizations' own internal
// GET /internal/memberships/active?user_id=<uid> (services/organizations/api/
// memberships.go's getActiveMembership) — the same endpoint the shared
// authn.NewOrgResolver middleware already calls to resolve the CALLER's own
// org, so this is a proven, already-tested upstream contract, not a new one.
type MemberVerifier struct {
	organizationsURL string
	client           *http.Client
}

// NewMemberVerifier builds a verifier targeting organizationsURL (the
// operator-configured internal base URL, INTERNAL_ORGANIZATIONS_URL — never
// a client-supplied value). A nil client defaults to a 5s-timeout,
// OTel-instrumented client, matching authn.NewOrgResolver's own default.
func NewMemberVerifier(organizationsURL string, client *http.Client) (*MemberVerifier, error) {
	if organizationsURL == "" {
		return nil, fmt.Errorf("todos: NewMemberVerifier requires organizationsURL")
	}
	if client == nil {
		client = &http.Client{
			Timeout:   5 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		}
	}
	return &MemberVerifier{
		// Trim a trailing slash so an operator-supplied URL never produces a
		// double slash when concatenated below (mirrors activities'
		// NewApiaryVerifier / services/sync/api/coordinator.go's NewCoordinator).
		organizationsURL: strings.TrimRight(organizationsURL, "/"),
		client:           client,
	}, nil
}

// BelongsToOrg reports whether assigneeID has an ACTIVE membership in
// callerOrgID — the caller's own resolved organization (never a
// client-supplied org id; requireOrg's result). bearer is the caller's OWN
// Authorization header, forwarded verbatim so organizations re-authenticates
// and re-derives its own view from the SAME verified token (zero-trust,
// auth.md §4) — todos never asserts an org value to organizations out of
// band.
//
//   - 404 (no active membership anywhere for assigneeID) → (false, nil): a
//     clean, expected "not assignable" outcome, never an error.
//   - 200 with organization_id != callerOrgID (a member of a DIFFERENT org —
//     the cross-tenant IDOR case) → (false, nil): also a clean rejection,
//     not distinguished from "unknown user" to the caller (ADR-0002
//     scope-hiding).
//   - 200 with organization_id == callerOrgID → (true, nil).
//   - any transport error or non-200/404 status → fail CLOSED: returns
//     ErrMembersUnavailable rather than defaulting to "assume valid" — a
//     REST caller surfaces this as 500, and sync-apply leaves the op queued
//     to heal on retry (see sync.go's resolveAssigneeOwnership).
func (v *MemberVerifier) BelongsToOrg(ctx context.Context, bearer, callerOrgID, assigneeID string) (bool, error) {
	reqURL := v.organizationsURL + "/internal/memberships/active?user_id=" + url.QueryEscape(assigneeID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return false, fmt.Errorf("build organizations request: %w", err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := v.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrMembersUnavailable, err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var out membershipDTO
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return false, fmt.Errorf("%w: decode membership response: %v", ErrMembersUnavailable, err)
		}
		return out.OrganizationID == callerOrgID, nil
	case http.StatusNotFound:
		// Drain (not decode — a 404 carries no membership body worth reading)
		// so the connection can be reused, capped defensively against a
		// misbehaving upstream, mirroring apiaries_client.go's own drain.
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return false, nil
	default:
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return false, fmt.Errorf("%w: organizations responded %d", ErrMembersUnavailable, resp.StatusCode)
	}
}
