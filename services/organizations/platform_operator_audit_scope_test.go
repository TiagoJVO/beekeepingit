package main

// Integration tests for #470 (FR-HIS-1, NFR-SEC-1, FR-TEN-2): the persisted
// organizations.audit_log.actor_scope column (migration 00005) that
// distinguishes a history row written by an ordinary organization
// member/admin ("member") from one written by a verified platform operator
// acting outside their own membership ("platform_operator", #466's carve-out,
// ADR-0021). Reuses platform_operator_authz_test.go's newPlatformOrgFixture,
// which already provisions org A (an admin + one plain "user" member) and a
// platform operator known to identity but a member of no organization.
//
// Coverage map (#470 AC "assert the attribution for BOTH an operator-
// performed and a member-performed action" on all three mutations #466
// wired to the platform path):
//   - TestAuditActorScope_OrganizationUpdate_MemberVsPlatformOperator
//   - TestAuditActorScope_RemoveMember_MemberVsPlatformOperator
//   - TestAuditActorScope_ChangeMemberRole_MemberVsPlatformOperator

import (
	"net/http"
	"testing"
)

// TestAuditActorScope_OrganizationUpdate_MemberVsPlatformOperator covers
// PATCH /organizations/{orgId}: an org admin's edit is attributed
// actor_scope="member"; a verified platform operator's edit of the SAME
// organization is attributed actor_scope="platform_operator" -- recorded in
// the same transaction as each write, not inferred afterwards.
func TestAuditActorScope_OrganizationUpdate_MemberVsPlatformOperator(t *testing.T) {
	pf := newPlatformOrgFixture(t)
	f := pf.f

	// Org A's own admin edits it -- the ordinary membership path.
	recAdmin := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+pf.orgA, pf.orgAAdminTok,
		map[string]string{"If-Match": "*"}, map[string]string{"name": "Org A (admin edit)"})
	if recAdmin.Code != http.StatusOK {
		t.Fatalf("admin PATCH org status = %d, want 200, body = %s", recAdmin.Code, recAdmin.Body.String())
	}

	// The verified platform operator edits the same organization it holds no
	// membership in -- the platform path (ADR-0021).
	operatorTok := f.platformOperatorToken(t, pf.operatorSub)
	recOperator := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+pf.orgA, operatorTok,
		map[string]string{"If-Match": "*"}, map[string]string{"name": "Org A (operator edit)"})
	if recOperator.Code != http.StatusOK {
		t.Fatalf("operator PATCH org status = %d, want 200, body = %s", recOperator.Code, recOperator.Body.String())
	}

	rows := f.auditLogFor(t, "organization", pf.orgA)
	if len(rows) < 3 {
		// create (by the admin) + the admin's update + the operator's update.
		t.Fatalf("organization audit rows = %d, want at least 3: %+v", len(rows), rows)
	}

	adminRow := rows[len(rows)-2]
	if adminRow.ActorUserID != pf.orgAAdminID {
		t.Fatalf("admin update actor_user_id = %q, want %q", adminRow.ActorUserID, pf.orgAAdminID)
	}
	if adminRow.ActorScope != "member" {
		t.Errorf("admin update actor_scope = %q, want %q", adminRow.ActorScope, "member")
	}

	operatorRow := rows[len(rows)-1]
	if operatorRow.ActorUserID != pf.operatorID {
		t.Fatalf("operator update actor_user_id = %q, want %q", operatorRow.ActorUserID, pf.operatorID)
	}
	if operatorRow.ActorScope != "platform_operator" {
		t.Errorf("operator update actor_scope = %q, want %q", operatorRow.ActorScope, "platform_operator")
	}
}

// TestAuditActorScope_RemoveMember_MemberVsPlatformOperator covers
// DELETE /organizations/{orgId}/members/{userId}: a real org admin's removal
// of a member is attributed actor_scope="member"; a verified platform
// operator's removal of a (different) member of the same organization it
// holds no membership in is attributed actor_scope="platform_operator".
// Uses two independent platformOrgFixtures (each provisions its own org A
// with exactly one removable plain member) rather than removing the same
// member twice in one fixture.
func TestAuditActorScope_RemoveMember_MemberVsPlatformOperator(t *testing.T) {
	t.Run("by the organization's own admin", func(t *testing.T) {
		pf := newPlatformOrgFixture(t)
		f := pf.f

		rec := f.do(t, http.MethodDelete, "/v1/organizations/"+pf.orgA+"/members/"+pf.orgAMemberID, pf.orgAAdminTok, nil)
		if rec.Code != http.StatusNoContent {
			t.Fatalf("admin remove-member status = %d, want 204, body = %s", rec.Code, rec.Body.String())
		}

		rows := membershipAuditRowsFor(t, f, pf.orgA, pf.orgAMemberID)
		last := rows[len(rows)-1]
		if last.ChangeType != "update" {
			t.Fatalf("last membership audit row change_type = %q, want update", last.ChangeType)
		}
		if last.ActorUserID != pf.orgAAdminID {
			t.Errorf("remove-member actor_user_id = %q, want %q (the org's own admin)", last.ActorUserID, pf.orgAAdminID)
		}
		if last.ActorScope != "member" {
			t.Errorf("remove-member actor_scope = %q, want %q", last.ActorScope, "member")
		}
	})

	t.Run("by a verified platform operator", func(t *testing.T) {
		pf := newPlatformOrgFixture(t)
		f := pf.f
		operatorTok := f.platformOperatorToken(t, pf.operatorSub)

		rec := f.do(t, http.MethodDelete, "/v1/organizations/"+pf.orgA+"/members/"+pf.orgAMemberID, operatorTok, nil)
		if rec.Code != http.StatusNoContent {
			t.Fatalf("operator remove-member status = %d, want 204, body = %s", rec.Code, rec.Body.String())
		}

		rows := membershipAuditRowsFor(t, f, pf.orgA, pf.orgAMemberID)
		last := rows[len(rows)-1]
		if last.ChangeType != "update" {
			t.Fatalf("last membership audit row change_type = %q, want update", last.ChangeType)
		}
		if last.ActorUserID != pf.operatorID {
			t.Errorf("remove-member actor_user_id = %q, want %q (the operator, not org A's admin %q)", last.ActorUserID, pf.operatorID, pf.orgAAdminID)
		}
		if last.ActorScope != "platform_operator" {
			t.Errorf("remove-member actor_scope = %q, want %q", last.ActorScope, "platform_operator")
		}
	})
}

// TestAuditActorScope_ChangeMemberRole_MemberVsPlatformOperator covers
// PATCH /organizations/{orgId}/members/{userId}: a real org admin's
// promotion of a member is attributed actor_scope="member"; a verified
// platform operator's promotion of a (different fixture's) member of the
// same organization it holds no membership in is attributed
// actor_scope="platform_operator".
func TestAuditActorScope_ChangeMemberRole_MemberVsPlatformOperator(t *testing.T) {
	t.Run("by the organization's own admin", func(t *testing.T) {
		pf := newPlatformOrgFixture(t)
		f := pf.f

		rec := f.do(t, http.MethodPatch, "/v1/organizations/"+pf.orgA+"/members/"+pf.orgAMemberID, pf.orgAAdminTok,
			map[string]string{"role": "admin"})
		if rec.Code != http.StatusOK {
			t.Fatalf("admin change-role status = %d, want 200, body = %s", rec.Code, rec.Body.String())
		}

		rows := membershipAuditRowsFor(t, f, pf.orgA, pf.orgAMemberID)
		last := rows[len(rows)-1]
		if last.ActorUserID != pf.orgAAdminID {
			t.Errorf("change-role actor_user_id = %q, want %q (the org's own admin)", last.ActorUserID, pf.orgAAdminID)
		}
		if last.ActorScope != "member" {
			t.Errorf("change-role actor_scope = %q, want %q", last.ActorScope, "member")
		}
	})

	t.Run("by a verified platform operator", func(t *testing.T) {
		pf := newPlatformOrgFixture(t)
		f := pf.f
		operatorTok := f.platformOperatorToken(t, pf.operatorSub)

		rec := f.do(t, http.MethodPatch, "/v1/organizations/"+pf.orgA+"/members/"+pf.orgAMemberID, operatorTok,
			map[string]string{"role": "admin"})
		if rec.Code != http.StatusOK {
			t.Fatalf("operator change-role status = %d, want 200, body = %s", rec.Code, rec.Body.String())
		}

		rows := membershipAuditRowsFor(t, f, pf.orgA, pf.orgAMemberID)
		last := rows[len(rows)-1]
		if last.ActorUserID != pf.operatorID {
			t.Errorf("change-role actor_user_id = %q, want %q (the operator, not org A's admin %q)", last.ActorUserID, pf.operatorID, pf.orgAAdminID)
		}
		if last.ActorScope != "platform_operator" {
			t.Errorf("change-role actor_scope = %q, want %q", last.ActorScope, "platform_operator")
		}
	})
}

// membershipAuditRowsFor returns every organizations.audit_log row for one
// membership, oldest first, resolved by (orgID, userID) via membershipID
// (member_lifecycle_test.go) -- entity_id is the membership row's own id,
// never returned by any response body, so tests that need it look it up
// directly, mirroring member_lifecycle_test.go's own audit assertions.
func membershipAuditRowsFor(t *testing.T, f *orgFixture, orgID, userID string) []auditRow {
	t.Helper()
	return f.auditLogFor(t, "membership", membershipID(t, f, orgID, userID))
}
