package main

// Integration tests for GET /organizations (#467, D-32, EPIC-18 #463): the
// platform-operator-only cross-org list. The authorization-boundary tests
// reuse newPlatformOrgFixture's org A / org B / operator setup
// (platform_operator_authz_test.go) exactly like that file's own tests do;
// pagination/search need more than two organizations with distinct,
// searchable names, so they use their own dedicated fixture
// (newListOrgsFixture below).
//
// Coverage map (#467 AC):
//   - TestListOrganizations_PlatformOperator_Succeeds: the positive case --
//     a verified operator, member of NEITHER org A nor org B, lists both,
//     with a correct member_count and no member PII anywhere in the body.
//   - TestListOrganizations_NonOperatorCallers_Return403: an org A admin, an
//     org A plain member, and a caller with no organization at all are all
//     rejected with 403 (not 404 -- there is no {orgId} here to hide the
//     existence of, per #466's handoff comment / ADR-0021's Follow-ups).
//   - TestListOrganizations_GroupsClaimAlone_Returns403: the `groups`
//     landmine (#465 handoff comment) -- a token carrying
//     `groups: ["platform-operator"]` but not the verified `platform_operator`
//     boolean must not be granted this endpoint either.
//   - TestListOrganizations_Unauthenticated_Returns401: no bearer at all.
//   - TestListOrganizations_Pagination: keyset pagination pages through
//     every organization exactly once.
//   - TestListOrganizations_SearchByName /
//     TestListOrganizations_SearchWithLiteralWildcardCharacters: `q` filters
//     by name, case-insensitively, and does not let a literal `%`/`_` in the
//     query act as a SQL wildcard.
//   - TestListOrganizations_ResponseConformsToOpenAPIContract: the response
//     body matches contracts/openapi/organizations.openapi.yaml.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
)

// organizationListBody mirrors organizationListResponse (api/organizations.go)
// for decoding in these tests.
type organizationListBody struct {
	Data []api.OrganizationSummaryResponse `json:"data"`
	Page struct {
		NextCursor *string `json:"next_cursor"`
		Limit      int     `json:"limit"`
	} `json:"page"`
}

// TestListOrganizations_PlatformOperator_Succeeds is the #467 positive AC: a
// verified platform operator -- a member of NEITHER org A nor org B -- lists
// every organization on the platform. member_count matches each org's real
// active-membership count (org A: admin + one plain member = 2; org B: admin
// only = 1), and no member PII (user_id/role/status/email) or any identifier
// belonging to a specific member appears anywhere in the response.
func TestListOrganizations_PlatformOperator_Succeeds(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f
	operatorTok := f.platformOperatorToken(t, pf.operatorSub)

	rec := f.do(t, http.MethodGet, "/v1/organizations", operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("operator list organizations status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	var body organizationListBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	byID := map[string]api.OrganizationSummaryResponse{}
	for _, org := range body.Data {
		byID[org.ID] = org
	}
	orgA, ok := byID[pf.orgA]
	if !ok {
		t.Fatalf("org A missing from operator's list: %+v", body.Data)
	}
	if orgA.Name != "Org A" || orgA.MemberCount != 2 {
		t.Errorf("org A summary = %+v, want name=Org A member_count=2", orgA)
	}
	orgB, ok := byID[pf.orgB]
	if !ok {
		t.Fatalf("org B missing from operator's list: %+v", body.Data)
	}
	if orgB.Name != "Org B" || orgB.MemberCount != 1 {
		t.Errorf("org B summary = %+v, want name=Org B member_count=1", orgB)
	}

	// No member PII, no invitation data, nothing from inside any
	// organization (#467 AC) -- neither a specific member's identifiers nor
	// any of the Member/Invitation schema's own field names should appear.
	raw := rec.Body.String()
	for _, leak := range []string{pf.orgAAdminID, pf.orgAMemberID, pf.memberEmail, `"role"`, `"status"`, `"user_id"`, `"email"`, `"created_by"`} {
		if strings.Contains(raw, leak) {
			t.Errorf("list organizations response leaks %q -- must expose nothing from inside any organization: %s", leak, raw)
		}
	}
}

// TestListOrganizations_NonOperatorCallers_Return403 is the adversarial
// regression this story lives or dies on: a caller without the verified
// platform_operator claim must be rejected regardless of how privileged they
// are within their OWN organization -- an org admin gets exactly the same
// 403 a plain member or a caller with no organization at all gets. Per
// #466's handoff comment on this issue and ADR-0021's Follow-ups section,
// this is 403 (not 404, unlike every {orgId}-scoped platform-operator route
// in platform_authz.go): there is no specific organization's existence to
// hide here, since this operation IS "list every organization".
func TestListOrganizations_NonOperatorCallers_Return403(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f

	noOrgSub := "c0000007-0000-4000-8000-000000000007"
	noOrgID := "c0000000-0000-7000-8000-0000000000c7"
	f.identity.users[noOrgSub] = stubUser{UserID: noOrgID}
	noOrgTok := f.token(t, noOrgSub)

	cases := []struct {
		name   string
		bearer string
	}{
		{name: "org admin (not a platform operator)", bearer: pf.orgAAdminTok},
		{name: "plain member (not a platform operator)", bearer: pf.orgAMemberTok},
		{name: "admin of a different organization (not a platform operator)", bearer: pf.orgBAdminTok},
		{name: "authenticated caller with no organization at all", bearer: noOrgTok},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodGet, "/v1/organizations", tc.bearer, nil)
			if rec.Code != http.StatusForbidden {
				t.Errorf("status = %d, want 403 (not 404 -- #467/ADR-0021: no {orgId} here to hide the existence of), body = %s", rec.Code, rec.Body.String())
			}
		})
	}
}

// TestListOrganizations_GroupsClaimAlone_Returns403 is the #465 landmine
// regression (handoff comment on #466, restated on #467): Authentik's
// managed `profile` scope mapping emits `groups` containing
// "platform-operator" on BOTH OIDC clients, so a real beekeepingit-pwa token
// for an operator lists that group too. A token carrying ONLY
// `groups: ["platform-operator"]` -- no verified `platform_operator` boolean
// -- must be rejected exactly like any other non-operator caller.
func TestListOrganizations_GroupsClaimAlone_Returns403(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f

	pwaSub := "c0000008-0000-4000-8000-000000000008"
	pwaUserID := "c0000000-0000-7000-8000-0000000000d8"
	f.identity.users[pwaSub] = stubUser{UserID: pwaUserID}
	groupsTok := f.groupsOnlyToken(t, pwaSub)

	rec := f.do(t, http.MethodGet, "/v1/organizations", groupsTok, nil)
	if rec.Code != http.StatusForbidden {
		t.Errorf("groups-only token status = %d, want 403 (groups must never grant platform access), body = %s", rec.Code, rec.Body.String())
	}
}

// TestListOrganizations_Unauthenticated_Returns401 asserts the endpoint
// requires a bearer token at all, same as every other route in this service.
func TestListOrganizations_Unauthenticated_Returns401(t *testing.T) {
	f := newOrgFixture(t, nil)
	rec := f.do(t, http.MethodGet, "/v1/organizations", "", nil)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401, body = %s", rec.Code, rec.Body.String())
	}
}

// TestListOrganizations_ExplicitPlatformOperatorFalse_Returns403 covers a
// token that carries `platform_operator: false` explicitly, as distinct from
// simply omitting the claim (every other rejection test here omits it).
// isPlatformOperator (platform_authz.go) is a plain boolean read, so an
// explicit false and an absent claim are handled by the exact same code
// path -- this test makes that equivalence an asserted fact rather than an
// implicit assumption.
func TestListOrganizations_ExplicitPlatformOperatorFalse_Returns403(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f

	sub := "c000000a-0000-4000-8000-00000000000a"
	userID := "c000000a-0000-7000-8000-00000000000a"
	f.identity.users[sub] = stubUser{UserID: userID}
	falseOperatorTok := "Bearer " + f.idp.MintWithClaims(t, sub, organizationsTestAudience, map[string]any{
		"platform_operator": false,
	})

	rec := f.do(t, http.MethodGet, "/v1/organizations", falseOperatorTok, nil)
	if rec.Code != http.StatusForbidden {
		t.Errorf("explicit platform_operator=false status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}
}

// listOrgsFixture is the shared setup for pagination/search coverage: several
// organizations with distinct, searchable names, each owned by its own admin
// (the single-org-per-user invariant, C-1, means one admin can't own more
// than one), plus a platform operator known to identity but a member of
// none of them.
type listOrgsFixture struct {
	f *orgFixture

	orgIDs      []string // creation order
	operatorTok string
}

func newListOrgsFixture(t *testing.T) *listOrgsFixture {
	t.Helper()
	f := newOrgFixture(t, nil)

	names := []string{"Alpha Apiaries", "Beta Bees", "Charlie Colonies", "Delta Drones", "Echo Extractors"}
	orgIDs := make([]string, len(names))
	for i, name := range names {
		sub := fmt.Sprintf("d0000000-0000-4000-8000-%012d", i+1)
		userID := fmt.Sprintf("d0000000-0000-7000-8000-%012d", i+1)
		f.identity.users[sub] = stubUser{UserID: userID}
		bearer := f.token(t, sub)
		orgID := fmt.Sprintf("e0000000-0000-7000-8000-%012d", i+1)
		if rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{"id": orgID, "name": name}); rec.Code != http.StatusCreated {
			t.Fatalf("create org %q status = %d, want 201, body = %s", name, rec.Code, rec.Body.String())
		}
		orgIDs[i] = orgID
	}

	operatorSub := "f0000000-0000-4000-8000-000000000001"
	operatorID := "f0000000-0000-7000-8000-000000000001"
	f.identity.users[operatorSub] = stubUser{UserID: operatorID}
	operatorTok := f.platformOperatorToken(t, operatorSub)

	return &listOrgsFixture{f: f, orgIDs: orgIDs, operatorTok: operatorTok}
}

// TestListOrganizations_Pagination is the #467 AC: keyset pagination behaves
// like every other list endpoint in this service (ListMembers'/
// ListInvitations' id-DESC convention, memberships.sql/invitations.sql) --
// limit is honored, next_cursor advances the caller through every
// organization exactly once with no repeats, and the last page reports a
// nil next_cursor.
func TestListOrganizations_Pagination(t *testing.T) {
	lf := newListOrgsFixture(t)
	f := lf.f

	seen := map[string]bool{}
	var cursor string
	pages := 0
	for {
		path := "/v1/organizations?limit=2"
		if cursor != "" {
			path += "&cursor=" + cursor
		}
		rec := f.do(t, http.MethodGet, path, lf.operatorTok, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("list organizations status = %d, want 200, body = %s", rec.Code, rec.Body.String())
		}
		var page organizationListBody
		if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if page.Page.Limit != 2 {
			t.Errorf("page limit = %d, want 2", page.Page.Limit)
		}
		if len(page.Data) == 0 {
			t.Fatalf("page returned zero organizations (cursor = %q)", cursor)
		}
		for _, org := range page.Data {
			if seen[org.ID] {
				t.Fatalf("organization %s returned on more than one page", org.ID)
			}
			seen[org.ID] = true
		}
		pages++
		if pages > 10 {
			t.Fatalf("pagination did not terminate after %d pages", pages)
		}
		if page.Page.NextCursor == nil {
			break
		}
		cursor = *page.Page.NextCursor
	}

	if len(seen) != len(lf.orgIDs) {
		t.Fatalf("total organizations seen across pages = %d, want %d", len(seen), len(lf.orgIDs))
	}
	for _, id := range lf.orgIDs {
		if !seen[id] {
			t.Errorf("organization %s never returned across any page", id)
		}
	}
}

// TestListOrganizations_SearchByName is the #467 AC "search/filter by
// name": `q` narrows the list to organizations whose name contains the
// query, case-insensitively, without the caller needing to page through
// every organization to find one.
func TestListOrganizations_SearchByName(t *testing.T) {
	lf := newListOrgsFixture(t)
	f := lf.f

	rec := f.do(t, http.MethodGet, "/v1/organizations?q=bee", lf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("search status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var body organizationListBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Data) != 1 || body.Data[0].Name != "Beta Bees" {
		t.Fatalf("search q=bee results = %+v, want exactly [Beta Bees] (case-insensitive substring match)", body.Data)
	}
}

// TestListOrganizations_SearchWithLiteralWildcardCharacters proves the `q`
// param's ILIKE wildcard characters (%, _) are escaped before reaching
// Postgres (likeSearchPattern, api/organizations.go): a caller searching for
// a LITERAL "%" in an organization name must not have it treated as a SQL
// wildcard that also matches an unrelated organization.
func TestListOrganizations_SearchWithLiteralWildcardCharacters(t *testing.T) {
	f := newOrgFixture(t, nil)

	sub1 := "d1000000-0000-4000-8000-000000000001"
	f.identity.users[sub1] = stubUser{UserID: "d1000000-0000-7000-8000-000000000001"}
	bearer1 := f.token(t, sub1)
	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearer1, map[string]string{
		"id": "e1000000-0000-7000-8000-000000000001", "name": "100% Honey Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	sub2 := "d1000000-0000-4000-8000-000000000002"
	f.identity.users[sub2] = stubUser{UserID: "d1000000-0000-7000-8000-000000000002"}
	bearer2 := f.token(t, sub2)
	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearer2, map[string]string{
		"id": "e1000000-0000-7000-8000-000000000002", "name": "1000 Honey Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	operatorSub := "f1000000-0000-4000-8000-000000000001"
	f.identity.users[operatorSub] = stubUser{UserID: "f1000000-0000-7000-8000-000000000001"}
	operatorTok := f.platformOperatorToken(t, operatorSub)

	// "%25" is the URL-encoded literal "%" -- a real client would encode it
	// the same way when the search text itself contains a percent sign.
	rec := f.do(t, http.MethodGet, "/v1/organizations?q=100%25", operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("search status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var body organizationListBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Data) != 1 || body.Data[0].Name != "100% Honey Co." {
		t.Fatalf(`search q="100%%" results = %+v, want exactly ["100%% Honey Co."] (literal %% must not act as a SQL wildcard also matching "1000 Honey Co.")`, body.Data)
	}
}

// TestListOrganizations_ResponseConformsToOpenAPIContract validates the real
// GET /organizations response body against
// contracts/openapi/organizations.openapi.yaml (#153 "contract tests at
// boundaries" convention), mirroring organizations_test.go's own
// TestOrganizations_ResponsesConformToOpenAPIContract.
func TestListOrganizations_ResponseConformsToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/organizations.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	pf := newPlatformOrgFixture(t)
	f := pf.f
	operatorTok := f.platformOperatorToken(t, pf.operatorSub)

	rec := f.do(t, http.MethodGet, "/v1/organizations", operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list organizations status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/organizations", http.StatusOK, rec.Body.Bytes())
}
