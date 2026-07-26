package main

// Integration tests for the #466 platform-operator authorization path:
// requirePlatformOperatorOrOrgMember/requirePlatformOperatorOrOrgAdmin
// (services/organizations/api/platform_authz.go), wired into getOrganization,
// updateOrganization, listMembersHandler, removeMemberHandler and
// changeMemberRoleHandler. These exercise the full authn + org-resolve chain
// over real HTTP against a real Postgres, reusing organizations_test.go's
// fixture helpers exactly like organizations_update_test.go and
// member_lifecycle_test.go do.
//
// Coverage map (#466 AC):
//   - TestPlatformOperator_CrossOrg_AllFiveEndpoints_Succeed: the positive
//     case -- a verified operator, member of NO organization, reaches all
//     five platform-path-enabled endpoints on an org it does not belong to.
//   - TestPlatformOperator_NonOperatorCallers_StillGet404_OnAllFiveEndpoints:
//     the adversarial regression this story lives or dies on -- an org admin
//     of a DIFFERENT org, and a caller with an active token but no
//     organization at all, both still get 404 (never 403, never data) on
//     every one of the five endpoints. Proves ADR-0002 is untouched for
//     everyone without the claim.
//   - TestPlatformOperator_GroupsClaimAlone_DoesNotGrantAccess: the
//     `groups` landmine (#465 handoff comment) -- a token carrying
//     `groups: ["platform-operator"]` but NOT the verified `platform_operator`
//     boolean must NOT be granted cross-org access.
//   - TestPlatformOperator_AuditAttributesToOperator: the operator's OWN
//     resolved user_id, not the org's own admin, is what lands in
//     organizations.audit_log.actor_user_id for a platform-path write --
//     the recoverability #470 will build on.

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
)

// platformOperatorToken mints a bearer token carrying a VERIFIED, genuinely
// signed `platform_operator: true` claim (authtest.MintWithClaims) -- not a
// context-injection test seam -- so these tests exercise the real
// authn.NewMiddleware extraction path (#465/#466), same as a real
// beekeepingit-admin-issued token would.
func (f *orgFixture) platformOperatorToken(t *testing.T, sub string) string {
	t.Helper()
	return "Bearer " + f.idp.MintWithClaims(t, sub, organizationsTestAudience, map[string]any{
		"platform_operator": true,
	})
}

// groupsOnlyToken mints a token carrying `groups: ["platform-operator"]` but
// NOT the `platform_operator` boolean claim -- the exact shape a real
// beekeepingit-pwa token for an operator has today (oidc-integration.md
// §3.2). Used to prove this codebase's authorization path never falls back
// to `groups`.
func (f *orgFixture) groupsOnlyToken(t *testing.T, sub string) string {
	t.Helper()
	return "Bearer " + f.idp.MintWithClaims(t, sub, organizationsTestAudience, map[string]any{
		"groups": []string{"platform-operator"},
	})
}

// platformOrgFixture is the shared setup for this file's tests: org A (admin
// + one plain member), org B (a second admin, used as the "different org"
// adversarial caller), and a platform operator known to identity but a
// member of NEITHER organization.
type platformOrgFixture struct {
	f *orgFixture

	orgA          string
	orgAAdminSub  string
	orgAAdminID   string
	orgAMemberID  string
	memberEmail   string
	orgAAdminTok  string
	orgAMemberTok string

	orgB         string
	orgBAdminID  string
	orgBAdminTok string

	operatorSub string
	operatorID  string
}

func newPlatformOrgFixture(t *testing.T) *platformOrgFixture {
	t.Helper()

	orgAAdminSub := "c0000001-0000-4000-8000-000000000001"
	orgAAdminID := "c0000000-0000-7000-8000-0000000000a1"
	orgAMemberSub := "c0000002-0000-4000-8000-000000000002"
	orgAMemberID := "c0000000-0000-7000-8000-0000000000a2"
	memberEmail := "orga-member@example.com"
	orgBAdminSub := "c0000003-0000-4000-8000-000000000003"
	orgBAdminID := "c0000000-0000-7000-8000-0000000000b1"
	operatorSub := "c0000009-0000-4000-8000-000000000009"
	operatorID := "c0000000-0000-7000-8000-0000000000ff"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			orgAAdminSub:  {UserID: orgAAdminID},
			orgAMemberSub: {UserID: orgAMemberID, Email: memberEmail},
			orgBAdminSub:  {UserID: orgBAdminID},
			// The platform operator is a KNOWN identity user (a real
			// identity.users row an admin-client token could belong to) but
			// deliberately never invited/created into any organization --
			// exactly the "typically not a member of any organization"
			// shape D-32/auth.md §5.3.2 describes.
			operatorSub: {UserID: operatorID},
		},
		map[string]tokenClaim{
			orgAMemberSub: {Email: memberEmail, EmailVerified: true},
		},
	)

	orgAAdminTok := f.token(t, orgAAdminSub)
	orgAMemberTok := f.token(t, orgAMemberSub)
	orgBAdminTok := f.token(t, orgBAdminSub)

	orgA := "d0000000-0000-7000-8000-00000000000a"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", orgAAdminTok,
		map[string]string{"id": orgA, "name": "Org A", "address": "A Street"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org A status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	addAcceptedMember(t, f, orgAAdminTok, orgAMemberTok, orgA, memberEmail, "user")

	orgB := "d0000000-0000-7000-8000-00000000000b"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", orgBAdminTok,
		map[string]string{"id": orgB, "name": "Org B", "address": "B Street"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org B status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	return &platformOrgFixture{
		f: f,

		orgA:          orgA,
		orgAAdminSub:  orgAAdminSub,
		orgAAdminID:   orgAAdminID,
		orgAMemberID:  orgAMemberID,
		memberEmail:   memberEmail,
		orgAAdminTok:  orgAAdminTok,
		orgAMemberTok: orgAMemberTok,

		orgB:         orgB,
		orgBAdminID:  orgBAdminID,
		orgBAdminTok: orgBAdminTok,

		operatorSub: operatorSub,
		operatorID:  operatorID,
	}
}

// TestPlatformOperator_CrossOrg_AllFiveEndpoints_Succeed is the #466 positive
// AC: a verified platform operator -- a member of NO organization -- reaches
// every platform-path-enabled endpoint on org A, which it does not belong to.
func TestPlatformOperator_CrossOrg_AllFiveEndpoints_Succeed(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f
	operatorTok := f.platformOperatorToken(t, pf.operatorSub)

	// GET /organizations/{orgId}: 200, and the response's `role` reflects the
	// platform-operator grant (platformOperatorRole = "admin" -- the wire
	// contract's Role enum is closed to [admin, user], see platform_authz.go).
	recGet := f.do(t, http.MethodGet, "/v1/organizations/"+pf.orgA, operatorTok, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("operator GET org status = %d, want 200, body = %s", recGet.Code, recGet.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode organization: %v", err)
	}
	if org.Name != "Org A" {
		t.Errorf("org name = %q, want Org A", org.Name)
	}
	if org.Role != "admin" {
		t.Errorf("role = %q, want admin (platform-operator grant)", org.Role)
	}

	// PATCH /organizations/{orgId}: 200, the edit applies.
	recPatch := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+pf.orgA, operatorTok,
		map[string]string{"If-Match": "*"},
		map[string]string{"name": "Org A (renamed by platform operator)"})
	if recPatch.Code != http.StatusOK {
		t.Fatalf("operator PATCH org status = %d, want 200, body = %s", recPatch.Code, recPatch.Body.String())
	}

	// GET /organizations/{orgId}/members: 200, lists org A's real members.
	recMembers := f.do(t, http.MethodGet, "/v1/organizations/"+pf.orgA+"/members", operatorTok, nil)
	if recMembers.Code != http.StatusOK {
		t.Fatalf("operator list members status = %d, want 200, body = %s", recMembers.Code, recMembers.Body.String())
	}

	// PATCH /organizations/{orgId}/members/{userId}: promote the plain member
	// to admin -- 200.
	recRole := f.do(t, http.MethodPatch, "/v1/organizations/"+pf.orgA+"/members/"+pf.orgAMemberID, operatorTok,
		map[string]string{"role": "admin"})
	if recRole.Code != http.StatusOK {
		t.Fatalf("operator change-role status = %d, want 200, body = %s", recRole.Code, recRole.Body.String())
	}

	// DELETE /organizations/{orgId}/members/{userId}: now that org A has two
	// admins (the last-admin guard, D-3, would otherwise block this), the
	// operator removes the original admin -- 204.
	recRemove := f.do(t, http.MethodDelete, "/v1/organizations/"+pf.orgA+"/members/"+pf.orgAAdminID, operatorTok, nil)
	if recRemove.Code != http.StatusNoContent {
		t.Fatalf("operator remove member status = %d, want 204, body = %s", recRemove.Code, recRemove.Body.String())
	}
}

// TestPlatformOperator_NonOperatorCallers_StillGet404_OnAllFiveEndpoints is
// the adversarial regression this story lives or dies on (#466 AC3):
// ADR-0002's 404-not-403 rule must be COMPLETELY unaffected for any caller
// that does not carry the verified claim. Two such callers are exercised
// against every platform-path-enabled endpoint on org A: an admin of a
// DIFFERENT organization (org B), and an authenticated caller with an active
// token but no organization at all. Neither is a platform operator, so both
// must get 404 on every single one -- never 403 (which would confirm org A
// exists), never data.
func TestPlatformOperator_NonOperatorCallers_StillGet404_OnAllFiveEndpoints(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f

	noOrgSub := "c0000005-0000-4000-8000-000000000005"
	noOrgID := "c0000000-0000-7000-8000-0000000000c5"
	// Register the caller with identity (a known user) but never create or
	// join any organization for them.
	f.identity.users[noOrgSub] = stubUser{UserID: noOrgID}
	noOrgTok := f.token(t, noOrgSub)

	memberPath := "/v1/organizations/" + pf.orgA + "/members/" + pf.orgAMemberID

	cases := []struct {
		name   string
		bearer string
	}{
		{name: "admin of a different organization", bearer: pf.orgBAdminTok},
		{name: "authenticated caller with no organization at all", bearer: noOrgTok},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if rec := f.do(t, http.MethodGet, "/v1/organizations/"+pf.orgA, tc.bearer, nil); rec.Code != http.StatusNotFound {
				t.Errorf("GET org status = %d, want 404, body = %s", rec.Code, rec.Body.String())
			}
			if rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+pf.orgA, tc.bearer,
				map[string]string{"If-Match": "*"}, map[string]string{"name": "Should Not Apply"}); rec.Code != http.StatusNotFound {
				t.Errorf("PATCH org status = %d, want 404, body = %s", rec.Code, rec.Body.String())
			}
			if rec := f.do(t, http.MethodGet, "/v1/organizations/"+pf.orgA+"/members", tc.bearer, nil); rec.Code != http.StatusNotFound {
				t.Errorf("list members status = %d, want 404, body = %s", rec.Code, rec.Body.String())
			}
			if rec := f.do(t, http.MethodPatch, memberPath, tc.bearer, map[string]string{"role": "admin"}); rec.Code != http.StatusNotFound {
				t.Errorf("change-role status = %d, want 404, body = %s", rec.Code, rec.Body.String())
			}
			if rec := f.do(t, http.MethodDelete, memberPath, tc.bearer, nil); rec.Code != http.StatusNotFound {
				t.Errorf("remove-member status = %d, want 404, body = %s", rec.Code, rec.Body.String())
			}
		})
	}

	// Org A is unaffected by any of the rejected attempts above.
	recGet := f.do(t, http.MethodGet, "/v1/organizations/"+pf.orgA, pf.orgAAdminTok, nil)
	var org api.OrganizationResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode organization: %v", err)
	}
	if org.Name != "Org A" {
		t.Errorf("org A name = %q, want unchanged Org A", org.Name)
	}
}

// TestPlatformOperator_GroupsClaimAlone_DoesNotGrantAccess is the #465
// landmine regression (handoff comment on #466): Authentik's managed
// `profile` scope mapping emits `groups` containing "platform-operator" on
// BOTH OIDC clients, so a real beekeepingit-pwa token for an operator lists
// that group too. A token carrying ONLY `groups: ["platform-operator"]` --
// no verified `platform_operator` boolean -- must be treated exactly like
// any other non-operator caller: 404 on cross-org access, never granted.
func TestPlatformOperator_GroupsClaimAlone_DoesNotGrantAccess(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f

	// A caller known to identity, in no organization, whose token lists the
	// `platform-operator` GROUP but not the dedicated boolean claim --
	// exactly the shape a PWA token for a real operator has today.
	pwaSub := "c0000006-0000-4000-8000-000000000006"
	pwaUserID := "c0000000-0000-7000-8000-0000000000d6"
	f.identity.users[pwaSub] = stubUser{UserID: pwaUserID}
	groupsTok := f.groupsOnlyToken(t, pwaSub)

	if rec := f.do(t, http.MethodGet, "/v1/organizations/"+pf.orgA, groupsTok, nil); rec.Code != http.StatusNotFound {
		t.Errorf("GET org with groups-only token status = %d, want 404 (groups must never grant platform access), body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+pf.orgA, groupsTok,
		map[string]string{"If-Match": "*"}, map[string]string{"name": "Should Not Apply"}); rec.Code != http.StatusNotFound {
		t.Errorf("PATCH org with groups-only token status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestPlatformOperator_AuditAttributesToOperator proves the recoverability
// #470's audit-attribution story needs: a platform-path write's
// organizations.audit_log.actor_user_id is the OPERATOR's own resolved
// user_id -- never org A's own admin, and never blank/zero -- even though the
// operator holds no membership row in org A at all.
func TestPlatformOperator_AuditAttributesToOperator(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f
	operatorTok := f.platformOperatorToken(t, pf.operatorSub)

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+pf.orgA, operatorTok,
		map[string]string{"If-Match": "*"},
		map[string]string{"name": "Org A (audited edit)"})
	if rec.Code != http.StatusOK {
		t.Fatalf("operator PATCH org status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	rows := f.auditLogFor(t, "organization", pf.orgA)
	if len(rows) == 0 {
		t.Fatalf("audit rows for org A = 0, want at least the create + this update")
	}
	last := rows[len(rows)-1]
	if last.ChangeType != "update" {
		t.Fatalf("last audit row change_type = %q, want update", last.ChangeType)
	}
	if last.ActorUserID != pf.operatorID {
		t.Errorf("update actor_user_id = %q, want %q (the platform operator's own resolved identity, not org A's admin %q)",
			last.ActorUserID, pf.operatorID, pf.orgAAdminID)
	}
}
