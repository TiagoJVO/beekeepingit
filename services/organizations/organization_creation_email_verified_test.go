package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
)

// TestCreateOrganization_EmailVerifiedGate pins #362's one code change: POST
// /v1/organizations asserts the caller's own verified `email_verified` claim
// (auth.md §3.4 "gate sensitive flows on it") instead of inheriting that
// guarantee from the identity provider's flow.
//
// Why assert it here at all, when #361/#366 (auth.md §8.10/§8.11) already hold
// every session behind the emailed one-time link: D-3's #362 amendment makes a
// verified email the *precondition* of the now-unrestricted organization-
// creation policy, and a precondition that only exists in provider flow
// configuration is one blueprint edit (or one alternative federation source,
// #363/#365) away from silently disappearing. This is the same defense-in-depth
// posture the #170 invitation gate already takes on the accept-on-login path
// (invitations_test.go's TestGetMyOrganization_UnverifiedEmail_DoesNotAutoAccept)
// — organizations decides for itself, from the token, whether the caller has
// proven inbox control.
//
// Unlike that accept-on-login path — where an unverified caller is deliberately
// indistinguishable from "no pending invitation", so verification state can't be
// probed through the endpoint — creation answers 403: there is nothing to hide
// here (the caller is asking about their *own* account state, not another org's
// existence), and the client's onboarding needs a distinguishable signal to tell
// the user to check their inbox.
func TestCreateOrganization_EmailVerifiedGate(t *testing.T) {
	const (
		verifiedSub      = "3620000a-0000-4000-8000-000000000001"
		unverifiedSub    = "3620000a-0000-4000-8000-000000000002"
		verifiedUserID   = "a3620000-0000-7000-8000-000000000001"
		unverifiedUserID = "a3620000-0000-7000-8000-000000000002"
	)
	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			verifiedSub:   {UserID: verifiedUserID, Email: "verified@example.test"},
			unverifiedSub: {UserID: unverifiedUserID, Email: "unverified@example.test"},
		},
		map[string]tokenClaim{
			verifiedSub:   {Email: "verified@example.test", EmailVerified: true},
			unverifiedSub: {Email: "unverified@example.test", EmailVerified: false},
		})

	doc, err := contracttest.Load("../../contracts/openapi/organizations.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	tests := []struct {
		name  string
		sub   string
		orgID string
		want  int
	}{
		{
			name:  "unverified email cannot create an organization",
			sub:   unverifiedSub,
			orgID: "b3620000-0000-7000-8000-000000000002",
			want:  http.StatusForbidden,
		},
		{
			name:  "verified email creates an organization",
			sub:   verifiedSub,
			orgID: "b3620000-0000-7000-8000-000000000001",
			want:  http.StatusCreated,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodPost, "/v1/organizations", f.token(t, tc.sub), map[string]string{
				"id": tc.orgID, "name": "Serra Norte Apiaries",
			})
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d, body = %s", rec.Code, tc.want, rec.Body.String())
			}
			if tc.want != http.StatusForbidden {
				return
			}
			// The rejection uses the repo's standard RFC 9457 envelope
			// (api-contracts.md §4/§7), and the contract now documents this
			// 403 on createOrganization.
			if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
				t.Errorf("Content-Type = %q, want application/problem+json", ct)
			}
			var p struct {
				Status int    `json:"status"`
				Code   string `json:"code"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
				t.Fatalf("decode problem: %v", err)
			}
			if p.Status != http.StatusForbidden || p.Code != "auth.forbidden" {
				t.Errorf("problem = %+v, want status 403 / code auth.forbidden", p)
			}
			doc.ValidateResponseBody(t, http.MethodPost, "/v1/organizations", http.StatusForbidden, rec.Body.Bytes())
		})
	}
}

// TestCreateOrganization_UnverifiedEmail_CreatesNothing proves the gate is a
// real precondition and not just a status code: the rejected caller must be
// left with no organization and no membership, so a later verified request
// still onboards from a clean slate (D-3 / FR-ONB-2).
func TestCreateOrganization_UnverifiedEmail_CreatesNothing(t *testing.T) {
	const (
		sub    = "3620000b-0000-4000-8000-000000000001"
		userID = "a3620001-0000-7000-8000-000000000001"
		orgID  = "b3620001-0000-7000-8000-000000000001"
	)
	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{sub: {UserID: userID, Email: "held@example.test"}},
		map[string]tokenClaim{sub: {Email: "held@example.test", EmailVerified: false}})
	bearer := f.token(t, sub)

	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": orgID, "name": "Held Apiaries",
	}); rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}

	var orgs, memberships int
	if err := f.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM organizations.organizations`).Scan(&orgs); err != nil {
		t.Fatalf("count organizations: %v", err)
	}
	if err := f.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM organizations.memberships`).Scan(&memberships); err != nil {
		t.Fatalf("count memberships: %v", err)
	}
	if orgs != 0 || memberships != 0 {
		t.Errorf("organizations/memberships = %d/%d, want 0/0 — the rejected create must write nothing", orgs, memberships)
	}
}
