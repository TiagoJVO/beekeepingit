package main

// Integration tests for the #468 platform-operator cross-organization
// membership lookup (services/organizations/api/platform_membership_lookup.go):
// GET /v1/organizations/platform/memberships, keyed by email or user_id.
// These exercise the full authn + resolver + Postgres chain over real HTTP,
// reusing organizations_test.go's fixture helpers and
// platform_operator_authz_test.go's platformOperatorToken/groupsOnlyToken.
//
// Coverage map (#468 AC):
//   - TestPlatformMembershipLookup_ByUserID_CrossOrgAndRemoved_Succeeds /
//     TestPlatformMembershipLookup_ByEmail_ResolvesAndReturnsSameResult: the
//     positive case -- a verified operator looks up a person with an ACTIVE
//     membership in one org and a REMOVED membership in another, by user_id
//     and (separately) by email, and gets both, with the right role/status
//     each.
//   - TestPlatformMembershipLookup_ZeroMemberships_ReturnsEmptyNotError /
//     TestPlatformMembershipLookup_UnknownEmail_ReturnsEmptyNotError: a known
//     identity with no memberships, and an email matching no identity at
//     all, both come back 200 with an empty list, never an error.
//   - TestPlatformMembershipLookup_NonOperator_Returns403 /
//     TestPlatformMembershipLookup_GroupsClaimAlone_Returns403: every
//     non-operator caller is rejected with 403 (never 404 -- there is no
//     {orgId} in this path to hide, per #466's handoff comment on this
//     issue), including the `groups`-claim-alone landmine regression.
//   - TestPlatformMembershipLookup_ParamValidation_Returns422: missing both
//     of / supplying both email and user_id / a malformed user_id.
//   - TestPlatformMembershipLookup_ResponseNeverLeaksCredentialsOrEmail: the
//     raw JSON response is inspected field-by-field to prove it carries only
//     organization_id/organization_name/role/status (+ the echoed user_id) --
//     never the target's email, a token, or any other IdP account internal
//     (D-7).
//   - TestPlatformMembershipLookup_ResponsesConformToOpenAPIContract: the
//     real response body validates against
//     contracts/openapi/organizations.openapi.yaml's PlatformMembershipList
//     schema.

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
)

// membershipLookupFixture is the shared setup for this file's tests: org X
// and org Y, each with their own admin; a person P invited into org X as a
// plain user (then removed) and into org Y as an admin (still active) --
// one person with a cross-organization, mixed role/status history, exactly
// the #468 support scenario; and a platform operator known to identity but a
// member of neither organization.
type membershipLookupFixture struct {
	f *orgFixture

	orgX     string
	orgXName string
	orgY     string
	orgYName string

	personUserID string
	personEmail  string

	operatorTok string
}

func newMembershipLookupFixture(t *testing.T) *membershipLookupFixture {
	t.Helper()

	adminXSub := "e0000001-0000-4000-8000-000000000001"
	adminXID := "e0000000-0000-7000-8000-0000000000a1"
	adminYSub := "e0000002-0000-4000-8000-000000000002"
	adminYID := "e0000000-0000-7000-8000-0000000000a2"
	personSub := "e0000003-0000-4000-8000-000000000003"
	personID := "e0000000-0000-7000-8000-0000000000a3"
	personEmail := "person-of-interest@example.com"
	operatorSub := "e0000009-0000-4000-8000-000000000009"
	operatorID := "e0000000-0000-7000-8000-0000000000ff"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminXSub:   {UserID: adminXID},
			adminYSub:   {UserID: adminYID},
			personSub:   {UserID: personID, Email: personEmail},
			operatorSub: {UserID: operatorID},
		},
		map[string]tokenClaim{
			personSub: {Email: personEmail, EmailVerified: true},
		},
	)

	adminXTok := f.token(t, adminXSub)
	adminYTok := f.token(t, adminYSub)
	personTok := f.token(t, personSub)

	orgX := "e1000000-0000-7000-8000-00000000000a"
	orgXName := "Org X"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminXTok,
		map[string]string{"id": orgX, "name": orgXName}); rec.Code != http.StatusCreated {
		t.Fatalf("create org X status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	// P joins org X as a plain user, then is removed -- a REMOVED membership
	// this lookup must still surface (unlike the org-scoped member list).
	addAcceptedMember(t, f, adminXTok, personTok, orgX, personEmail, "user")
	if rec := f.do(t, http.MethodDelete, "/v1/organizations/"+orgX+"/members/"+personID, adminXTok, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("remove person from org X status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	orgY := "e1000000-0000-7000-8000-00000000000b"
	orgYName := "Org Y"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminYTok,
		map[string]string{"id": orgY, "name": orgYName}); rec.Code != http.StatusCreated {
		t.Fatalf("create org Y status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	// P joins org Y as admin and stays active -- freed to join by org X's
	// removal above (C-1, single active membership per user).
	addAcceptedMember(t, f, adminYTok, personTok, orgY, personEmail, "admin")

	return &membershipLookupFixture{
		f: f,

		orgX:     orgX,
		orgXName: orgXName,
		orgY:     orgY,
		orgYName: orgYName,

		personUserID: personID,
		personEmail:  personEmail,

		operatorTok: f.platformOperatorToken(t, operatorSub),
	}
}

// assertHasXRemovedUserAndYActiveAdmin is the shared assertion both the
// by-user_id and by-email positive tests share: exactly org X (removed,
// user) and org Y (active, admin) are present, in EITHER order -- membership
// ids are random (uuid.New(), not time-ordered), so ORDER BY id DESC is a
// stable pagination key, not a chronological guarantee.
func (mf *membershipLookupFixture) assertHasXRemovedUserAndYActiveAdmin(t *testing.T, data []api.PlatformMembershipResponse) {
	t.Helper()
	if len(data) != 2 {
		t.Fatalf("data = %+v, want exactly 2 memberships", data)
	}
	byOrg := map[string]api.PlatformMembershipResponse{}
	for _, m := range data {
		byOrg[m.OrganizationID] = m
	}
	x, ok := byOrg[mf.orgX]
	if !ok {
		t.Fatalf("data = %+v, want an entry for org X (%s)", data, mf.orgX)
	}
	if x.OrganizationName != mf.orgXName || x.Role != "user" || x.Status != "removed" {
		t.Errorf("org X entry = %+v, want {name:%s role:user status:removed}", x, mf.orgXName)
	}
	y, ok := byOrg[mf.orgY]
	if !ok {
		t.Fatalf("data = %+v, want an entry for org Y (%s)", data, mf.orgY)
	}
	if y.OrganizationName != mf.orgYName || y.Role != "admin" || y.Status != "active" {
		t.Errorf("org Y entry = %+v, want {name:%s role:admin status:active}", y, mf.orgYName)
	}
}

// TestPlatformMembershipLookup_ByUserID_CrossOrgAndRemoved_Succeeds is the
// #468 core positive AC: a verified platform operator looks up a person by
// user_id and sees both their active membership in one org and their
// removed membership in another, each with the right role/status.
func TestPlatformMembershipLookup_ByUserID_CrossOrgAndRemoved_Succeeds(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?user_id="+mf.personUserID, mf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var body struct {
		UserID *string                          `json:"user_id"`
		Data   []api.PlatformMembershipResponse `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.UserID == nil || *body.UserID != mf.personUserID {
		t.Errorf("user_id = %v, want %q", body.UserID, mf.personUserID)
	}
	mf.assertHasXRemovedUserAndYActiveAdmin(t, body.Data)
}

// TestPlatformMembershipLookup_ByEmail_ResolvesAndReturnsSameResult proves
// the email-keyed lookup path (UserResolver.ResolveByEmail ->
// identity's GET /internal/users/by-email/{email}, #468) resolves to the
// same person and the same cross-org result as the user_id-keyed lookup
// above -- and that the match is case-insensitive.
func TestPlatformMembershipLookup_ByEmail_ResolvesAndReturnsSameResult(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?email=PERSON-OF-INTEREST@EXAMPLE.COM", mf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var body struct {
		UserID *string                          `json:"user_id"`
		Data   []api.PlatformMembershipResponse `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.UserID == nil || *body.UserID != mf.personUserID {
		t.Errorf("user_id = %v, want %q (resolved from email)", body.UserID, mf.personUserID)
	}
	mf.assertHasXRemovedUserAndYActiveAdmin(t, body.Data)
}

// TestPlatformMembershipLookup_ZeroMemberships_ReturnsEmptyNotError is the
// #468 AC's "person with zero memberships" case: a known identity user who
// never joined any organization gets 200 with an empty list, not a 404 or
// any other error.
func TestPlatformMembershipLookup_ZeroMemberships_ReturnsEmptyNotError(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	noOrgUserID := "e0000000-0000-7000-8000-0000000000c5"
	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?user_id="+noOrgUserID, mf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var body struct {
		UserID *string                          `json:"user_id"`
		Data   []api.PlatformMembershipResponse `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.UserID == nil || *body.UserID != noOrgUserID {
		t.Errorf("user_id = %v, want %q", body.UserID, noOrgUserID)
	}
	if len(body.Data) != 0 {
		t.Errorf("data = %+v, want empty", body.Data)
	}
}

// TestPlatformMembershipLookup_UnknownEmail_ReturnsEmptyNotError covers an
// email that resolves to no identity.users row at all (never registered, or
// a typo) -- also 200 with an empty list and a null user_id, never a 404
// (which would let an operator probe "does this email exist" as a distinct
// signal from "exists with zero memberships" -- deliberately collapsed,
// platform_membership_lookup.go's doc comment).
func TestPlatformMembershipLookup_UnknownEmail_ReturnsEmptyNotError(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?email=nobody@example.com", mf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var body struct {
		UserID *string                          `json:"user_id"`
		Data   []api.PlatformMembershipResponse `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.UserID != nil {
		t.Errorf("user_id = %v, want nil (email matched no identity)", *body.UserID)
	}
	if len(body.Data) != 0 {
		t.Errorf("data = %+v, want empty", body.Data)
	}
}

// TestPlatformMembershipLookup_NonOperator_Returns403 is the #468 adversarial
// regression: an org admin (of a real, unrelated org) and an authenticated
// caller with no organization at all both get 403 -- never 404 (there is no
// {orgId} in this path to hide, unlike the five #466 routes) and never any
// membership data.
func TestPlatformMembershipLookup_NonOperator_Returns403(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	adminXTok := f.token(t, "e0000001-0000-4000-8000-000000000001")
	noOrgSub := "e0000005-0000-4000-8000-000000000005"
	f.identity.users[noOrgSub] = stubUser{UserID: "e0000000-0000-7000-8000-0000000000c6"}
	noOrgTok := f.token(t, noOrgSub)

	cases := []struct {
		name   string
		bearer string
	}{
		{name: "admin of a real organization", bearer: adminXTok},
		{name: "authenticated caller with no organization at all", bearer: noOrgTok},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?user_id="+mf.personUserID, tc.bearer, nil)
			if rec.Code != http.StatusForbidden {
				t.Errorf("status = %d, want 403, body = %s", rec.Code, rec.Body.String())
			}
		})
	}
}

// TestPlatformMembershipLookup_GroupsClaimAlone_Returns403 is the #465
// landmine regression for this endpoint specifically (mirrors
// platform_operator_authz_test.go's TestPlatformOperator_GroupsClaimAlone_DoesNotGrantAccess):
// a token carrying `groups: ["platform-operator"]` but NOT the verified
// `platform_operator` boolean claim must never be granted this cross-org
// read.
func TestPlatformMembershipLookup_GroupsClaimAlone_Returns403(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	pwaSub := "e0000006-0000-4000-8000-000000000006"
	f.identity.users[pwaSub] = stubUser{UserID: "e0000000-0000-7000-8000-0000000000d6"}
	groupsTok := f.groupsOnlyToken(t, pwaSub)

	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?user_id="+mf.personUserID, groupsTok, nil)
	if rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403 (groups must never grant platform access), body = %s", rec.Code, rec.Body.String())
	}
}

// TestPlatformMembershipLookup_ParamValidation_Returns422 covers the lookup
// key's mutual-exclusivity contract: neither param, both params, and a
// malformed user_id are each a 422, never a 500 or a silent wrong-branch
// pick.
func TestPlatformMembershipLookup_ParamValidation_Returns422(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	cases := []struct {
		name  string
		query string
	}{
		{name: "neither email nor user_id", query: ""},
		{name: "both email and user_id", query: "?email=" + mf.personEmail + "&user_id=" + mf.personUserID},
		{name: "malformed user_id", query: "?user_id=not-a-uuid"},
		{name: "malformed email", query: "?email=not-an-email"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships"+tc.query, mf.operatorTok, nil)
			if rec.Code != http.StatusUnprocessableEntity {
				t.Errorf("status = %d, want 422, body = %s", rec.Code, rec.Body.String())
			}
		})
	}
}

// TestPlatformMembershipLookup_ResponseNeverLeaksCredentialsOrEmail is the
// #468 AC's "returns membership/role/status only" contract, checked at the
// wire level: decode the response as a generic map tree and assert the ONLY
// keys anywhere in it are the documented ones -- organization_id,
// organization_name, role, status, user_id, data, page (+ its
// next_cursor/limit) -- so a future change that accidentally starts
// embedding the target's email, a token, or any other IdP account internal
// fails this test rather than silently shipping (D-7).
func TestPlatformMembershipLookup_ResponseNeverLeaksCredentialsOrEmail(t *testing.T) {
	mf := newMembershipLookupFixture(t)
	f := mf.f

	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?user_id="+mf.personUserID, mf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	var raw map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	allowedTop := map[string]bool{"user_id": true, "data": true, "page": true}
	for k := range raw {
		if !allowedTop[k] {
			t.Errorf("unexpected top-level field %q in response: %s", k, rec.Body.String())
		}
	}
	allowedMembership := map[string]bool{"organization_id": true, "organization_name": true, "role": true, "status": true}
	data, _ := raw["data"].([]any)
	for _, item := range data {
		m, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("data item is not an object: %+v", item)
		}
		for k, v := range m {
			if !allowedMembership[k] {
				t.Errorf("unexpected field %q (value %v) in a membership entry -- possible PII/credential leak: %s", k, v, rec.Body.String())
			}
		}
	}
	if page, ok := raw["page"].(map[string]any); ok {
		allowedPage := map[string]bool{"next_cursor": true, "limit": true}
		for k := range page {
			if !allowedPage[k] {
				t.Errorf("unexpected field %q in page: %s", k, rec.Body.String())
			}
		}
	}
}

// TestPlatformMembershipLookup_ResponsesConformToOpenAPIContract validates
// the real response body against
// contracts/openapi/organizations.openapi.yaml's PlatformMembershipList
// schema (#153 "contract tests at boundaries" convention).
func TestPlatformMembershipLookup_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/organizations.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	mf := newMembershipLookupFixture(t)
	f := mf.f

	rec := f.do(t, http.MethodGet, "/v1/organizations/platform/memberships?user_id="+mf.personUserID, mf.operatorTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/organizations/platform/memberships", http.StatusOK, rec.Body.Bytes())
}
