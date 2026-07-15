package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
)

// TestInvitations_AdminInvitesAndMemberAccepts is the end-to-end #27 AC path:
// the admin invites an email, and a different user whose *verified JWT
// email claim* matches it is joined to the inviting organization the next
// time it polls GET /organizations/me, rather than being prompted to create
// a new one. Uses newOrgFixtureWithEmailClaims (not newOrgFixtureWithEmails)
// specifically so the invitee's identity.users profile email
// (stubUser.Email) can be asserted as irrelevant to acceptance — only the
// token claim drives it; see TestGetMyOrganization_ProfileEmailCannotClaimInvitation
// for the regression test that email deliberately differs in.
func TestInvitations_AdminInvitesAndMemberAccepts(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	inviteeSub := "b2222222-2222-4222-8222-222222222222"
	inviteeUserID := "a0000000-0000-7000-8000-0000000000b2"
	inviteeEmail := "invitee@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:   {UserID: adminUserID},
			inviteeSub: {UserID: inviteeUserID, Email: inviteeEmail},
		},
		map[string]tokenClaim{
			inviteeSub: {Email: inviteeEmail, EmailVerified: true},
		},
	)
	adminBearer := f.token(t, adminSub)
	inviteeBearer := f.token(t, inviteeSub)

	orgID := "b0000000-0000-7000-8000-000000000101"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	// Before any invitation, the invitee has no org.
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", inviteeBearer, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("pre-invite GET /organizations/me status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}

	recInvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": inviteeEmail, "role": "user",
	})
	if recInvite.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, want 201, body = %s", recInvite.Code, recInvite.Body.String())
	}
	var invitation api.InvitationResponse
	if err := json.Unmarshal(recInvite.Body.Bytes(), &invitation); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if invitation.Email != inviteeEmail || invitation.Role != "user" || invitation.Status != "pending" {
		t.Errorf("invitation = %+v, want email=%s role=user status=pending", invitation, inviteeEmail)
	}

	// The admin sees it pending in the list (AC: "invitation state is
	// visible to the admin").
	recList := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations", adminBearer, nil)
	if recList.Code != http.StatusOK {
		t.Fatalf("list invitations status = %d, want 200, body = %s", recList.Code, recList.Body.String())
	}
	var list struct {
		Data []api.InvitationResponse `json:"data"`
	}
	if err := json.Unmarshal(recList.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(list.Data) != 1 || list.Data[0].Status != "pending" {
		t.Errorf("invitations list = %+v, want one pending invitation", list.Data)
	}

	// The invitee logs in (polls GET /organizations/me) and is auto-joined —
	// no org-creation prompt.
	recMe := f.do(t, http.MethodGet, "/v1/organizations/me", inviteeBearer, nil)
	if recMe.Code != http.StatusOK {
		t.Fatalf("GET /organizations/me status = %d, want 200, body = %s", recMe.Code, recMe.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(recMe.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.ID != orgID {
		t.Errorf("invitee's org id = %q, want %q", org.ID, orgID)
	}
	if org.Role != "user" {
		t.Errorf("invitee's role via accept-on-login = %q, want %q (invited role, #172)", org.Role, "user")
	}

	// The membership now shows up in the admin-facing member list, with the
	// invited role, and the invitation has flipped to accepted.
	recMembers := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/members", adminBearer, nil)
	if recMembers.Code != http.StatusOK {
		t.Fatalf("list members status = %d, want 200, body = %s", recMembers.Code, recMembers.Body.String())
	}
	var members struct {
		Data []api.MemberResponse `json:"data"`
	}
	if err := json.Unmarshal(recMembers.Body.Bytes(), &members); err != nil {
		t.Fatalf("decode: %v", err)
	}
	found := false
	for _, m := range members.Data {
		if m.UserID == inviteeUserID {
			found = true
			if m.Role != "user" || m.Status != "active" {
				t.Errorf("invitee membership = %+v, want role=user status=active", m)
			}
		}
	}
	if !found {
		t.Errorf("members = %+v, want the invitee present", members.Data)
	}

	recListAfter := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations", adminBearer, nil)
	var listAfter struct {
		Data []api.InvitationResponse `json:"data"`
	}
	if err := json.Unmarshal(recListAfter.Body.Bytes(), &listAfter); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(listAfter.Data) != 1 || listAfter.Data[0].Status != "accepted" {
		t.Errorf("invitations after accept = %+v, want one accepted invitation", listAfter.Data)
	}

	// A second GET /organizations/me for the invitee is now a plain active
	// membership lookup, not another accept attempt (the invitation is
	// already resolved) — asserts idempotency of repeated polling.
	recMeAgain := f.do(t, http.MethodGet, "/v1/organizations/me", inviteeBearer, nil)
	if recMeAgain.Code != http.StatusOK {
		t.Fatalf("second GET /organizations/me status = %d, want 200, body = %s", recMeAgain.Code, recMeAgain.Body.String())
	}
}

// TestGetMyOrganization_ProfileEmailCannotClaimInvitation is the regression
// test for the vulnerability found in #170 review: an attacker cannot
// self-edit their identity.users profile email (PATCH /v1/profile, #25) to
// match someone else's pending invitation and auto-join that org. The
// attacker's stub identity profile email is set to the victim's invited
// address, but their JWT's verified email claim is their own, different,
// verified address — acceptPendingInvitationByEmail must be driven by the
// token claim, so this must come back 404 ("no org yet"), never 200 with
// the target org.
func TestGetMyOrganization_ProfileEmailCannotClaimInvitation(t *testing.T) {
	adminSub := "22222222-3333-4222-8222-222222222233"
	victimEmail := "victim@example.com" // the address the org actually invited
	attackerSub := "33333333-4444-4333-8333-333333333344"
	attackerUserID := "a0000000-0000-7000-8000-0000000000aa"
	attackerOwnEmail := "attacker@example.com" // the attacker's own, verified address

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub: {UserID: "a0000000-0000-7000-8000-0000000000bb"},
			// The attacker's identity.users profile email is set to the
			// VICTIM's address (as if PATCH /v1/profile were abused) — this
			// is exactly the field the pre-fix code matched invitations
			// against.
			attackerSub: {UserID: attackerUserID, Email: victimEmail},
		},
		map[string]tokenClaim{
			// The attacker's JWT carries their OWN verified email, not the
			// victim's — a real OIDC token always does, since it's
			// signed server-side and not derived from the mutable profile.
			attackerSub: {Email: attackerOwnEmail, EmailVerified: true},
		},
	)
	adminBearer := f.token(t, adminSub)
	attackerBearer := f.token(t, attackerSub)

	orgID := "b0000000-0000-7000-8000-000000000107"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Victim Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	// The admin invites the victim's address (never the attacker's).
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": victimEmail, "role": "admin",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	// The attacker polls GET /organizations/me hoping their profile-email
	// match auto-joins them (at the invited admin role, no less). It must
	// not: their verified token email doesn't match the invitation.
	rec := f.do(t, http.MethodGet, "/v1/organizations/me", attackerBearer, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("attacker GET /organizations/me status = %d, want 404 (no unauthorized join), body = %s", rec.Code, rec.Body.String())
	}

	// The invitation is still pending — untouched by the attempt.
	recList := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations", adminBearer, nil)
	var list struct {
		Data []api.InvitationResponse `json:"data"`
	}
	if err := json.Unmarshal(recList.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(list.Data) != 1 || list.Data[0].Status != "pending" {
		t.Errorf("invitations after attack attempt = %+v, want the one invitation still pending", list.Data)
	}
}

// TestGetMyOrganization_UnverifiedEmailCannotClaimInvitation covers the
// auth.md §3.4 "gate sensitive flows on email_verified" requirement: even
// when the token's email claim textually matches a pending invitation,
// EmailVerified=false must not auto-accept it — treated identically to "no
// pending invitation" (a plain 404, not a distinguishable error).
func TestGetMyOrganization_UnverifiedEmailCannotClaimInvitation(t *testing.T) {
	adminSub := "44444444-5555-4444-8444-444444444455"
	inviteeSub := "55555555-6666-4555-8555-555555555566"
	inviteeEmail := "unverified@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:   {UserID: "a0000000-0000-7000-8000-0000000000cc"},
			inviteeSub: {UserID: "a0000000-0000-7000-8000-0000000000dd", Email: inviteeEmail},
		},
		map[string]tokenClaim{
			// Email matches the invitation exactly, but is NOT verified.
			inviteeSub: {Email: inviteeEmail, EmailVerified: false},
		},
	)
	adminBearer := f.token(t, adminSub)
	inviteeBearer := f.token(t, inviteeSub)

	orgID := "b0000000-0000-7000-8000-000000000108"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": inviteeEmail}); rec.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodGet, "/v1/organizations/me", inviteeBearer, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unverified-email invitee GET /organizations/me status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestCreateInvitation_NonAdmin_Returns403 covers auth.md §5.3: member and
// invitation management endpoints are admin-only, 403 for a plain user.
func TestCreateInvitation_NonAdmin_Returns403(t *testing.T) {
	adminSub := "c3333333-3333-4333-8333-333333333333"
	memberSub := "d4444444-4444-4444-8444-444444444444"
	memberEmail := "member@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:  {UserID: "a0000000-0000-7000-8000-0000000000c3"},
			memberSub: {UserID: "a0000000-0000-7000-8000-0000000000d4", Email: memberEmail},
		},
		map[string]tokenClaim{
			memberSub: {Email: memberEmail, EmailVerified: true},
		},
	)
	adminBearer := f.token(t, adminSub)
	memberBearer := f.token(t, memberSub)

	orgID := "b0000000-0000-7000-8000-000000000102"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	// Get memberSub into the org as a plain 'user' via the invite+accept path.
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": memberEmail}); rec.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", memberBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("accept via GET /organizations/me status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", memberBearer, map[string]string{"email": "someone-else@example.com"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin invite status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}

	recList := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/members", memberBearer, nil)
	if recList.Code != http.StatusForbidden {
		t.Fatalf("non-admin list members status = %d, want 403, body = %s", recList.Code, recList.Body.String())
	}
}

// TestCreateInvitation_DuplicatePending_Returns409 covers the partial unique
// index: a second invite to the same email while one is still pending is a
// conflict, not a duplicate row.
func TestCreateInvitation_DuplicatePending_Returns409(t *testing.T) {
	adminSub := "e5555555-5555-4555-8555-555555555555"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000e5"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000103"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	body := map[string]string{"email": "dup@example.com"}
	first := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, body)
	if first.Code != http.StatusCreated {
		t.Fatalf("first invite status = %d, want 201, body = %s", first.Code, first.Body.String())
	}
	second := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, body)
	if second.Code != http.StatusConflict {
		t.Fatalf("duplicate pending invite status = %d, want 409, body = %s", second.Code, second.Body.String())
	}
}

// TestRevokeInvitation_ThenReinvite covers revoke, plus that revoking frees
// the email up for a fresh invite (the partial unique index only guards
// *pending* rows).
func TestRevokeInvitation_ThenReinvite(t *testing.T) {
	adminSub := "f6666666-6666-4666-8666-666666666666"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000f6"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000104"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recInvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": "revoke-me@example.com"})
	if recInvite.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", recInvite.Code, recInvite.Body.String())
	}
	var invitation api.InvitationResponse
	if err := json.Unmarshal(recInvite.Body.Bytes(), &invitation); err != nil {
		t.Fatalf("decode: %v", err)
	}

	recRevoke := f.do(t, http.MethodDelete, "/v1/organizations/"+orgID+"/invitations/"+invitation.ID, adminBearer, nil)
	if recRevoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204, body = %s", recRevoke.Code, recRevoke.Body.String())
	}

	// Revoking twice is now "not pending anymore" — 404.
	recRevokeAgain := f.do(t, http.MethodDelete, "/v1/organizations/"+orgID+"/invitations/"+invitation.ID, adminBearer, nil)
	if recRevokeAgain.Code != http.StatusNotFound {
		t.Fatalf("second revoke status = %d, want 404, body = %s", recRevokeAgain.Code, recRevokeAgain.Body.String())
	}

	// The same email can be invited again now that the pending row is gone.
	recReinvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": "revoke-me@example.com"})
	if recReinvite.Code != http.StatusCreated {
		t.Fatalf("re-invite status = %d, want 201, body = %s", recReinvite.Code, recReinvite.Body.String())
	}
}

// TestCreateInvitation_InvalidEmail_Returns422 covers required-field
// validation on the invite request.
func TestCreateInvitation_InvalidEmail_Returns422(t *testing.T) {
	adminSub := "07777777-7777-4777-8777-777777777777"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-000000000f07"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000105"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": "not-an-email"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
}

// TestInvitations_ResponsesConformToOpenAPIContract validates the real
// invitation/member response bodies against
// contracts/openapi/organizations.openapi.yaml (#153 boundary-testing
// convention).
func TestInvitations_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/organizations.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	adminSub := "18888888-8888-4888-8888-888888888888"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-000000000f18"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000106"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recInvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": "contract@example.com"})
	if recInvite.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", recInvite.Code, recInvite.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", http.StatusCreated, recInvite.Body.Bytes())

	recList := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations", adminBearer, nil)
	if recList.Code != http.StatusOK {
		t.Fatalf("list invitations status = %d, want 200, body = %s", recList.Code, recList.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations", http.StatusOK, recList.Body.Bytes())

	recMembers := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/members", adminBearer, nil)
	if recMembers.Code != http.StatusOK {
		t.Fatalf("list members status = %d, want 200, body = %s", recMembers.Code, recMembers.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/organizations/"+orgID+"/members", http.StatusOK, recMembers.Body.Bytes())
}

// TestInvitations_History_InviteAcceptEachWriteOneAuditRow is #165's core AC
// for invitations: inviting, accepting (auto-join on login) each write
// exactly one organizations.audit_log row for the invitation entity, and
// acceptance additionally writes the new membership's own create row —
// mirroring apiaries' #59
// TestApiariesSlice_History_CreateUpdateDeleteEachProduceOneAuditRow.
func TestInvitations_History_InviteAcceptEachWriteOneAuditRow(t *testing.T) {
	adminSub := "e7777777-1111-4777-8777-1111111117e7"
	adminUserID := "a0000000-0000-7000-8000-0000000007e7"
	inviteeSub := "e8888888-2222-4888-8888-2222222228e8"
	inviteeUserID := "a0000000-0000-7000-8000-0000000008e8"
	inviteeEmail := "history-invitee@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:   {UserID: adminUserID},
			inviteeSub: {UserID: inviteeUserID, Email: inviteeEmail},
		},
		map[string]tokenClaim{
			inviteeSub: {Email: inviteeEmail, EmailVerified: true},
		},
	)
	adminBearer := f.token(t, adminSub)
	inviteeBearer := f.token(t, inviteeSub)

	orgID := "b0000000-0000-7000-8000-0000000007e7"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "History Invite Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recInvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": inviteeEmail, "role": "user",
	})
	if recInvite.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", recInvite.Code, recInvite.Body.String())
	}
	var invitation api.InvitationResponse
	if err := json.Unmarshal(recInvite.Body.Bytes(), &invitation); err != nil {
		t.Fatalf("decode: %v", err)
	}

	// The invite itself: one create row, actor = the inviting admin.
	rows := f.auditLogFor(t, "invitation", invitation.ID)
	if len(rows) != 1 {
		t.Fatalf("invitation audit rows after invite = %d, want 1: %+v", len(rows), rows)
	}
	inviteRow := rows[0]
	if inviteRow.ChangeType != "create" {
		t.Fatalf("invite audit change_type = %q, want create", inviteRow.ChangeType)
	}
	if inviteRow.ActorUserID != adminUserID {
		t.Fatalf("invite audit actor_user_id = %q, want %q (inviting admin)", inviteRow.ActorUserID, adminUserID)
	}
	var inviteChange map[string]any
	if err := json.Unmarshal(inviteRow.Change, &inviteChange); err != nil {
		t.Fatalf("unmarshal invite change: %v", err)
	}
	if inviteChange["email"] != inviteeEmail || inviteChange["role"] != "user" || inviteChange["status"] != "pending" {
		t.Fatalf("invite change = %+v, want email=%s role=user status=pending", inviteChange, inviteeEmail)
	}

	// Accept-on-login (GET /organizations/me): one update row on the
	// invitation (pending -> accepted), actor = the ACCEPTING user (not the
	// admin — there is no admin action on this path).
	recMe := f.do(t, http.MethodGet, "/v1/organizations/me", inviteeBearer, nil)
	if recMe.Code != http.StatusOK {
		t.Fatalf("GET /organizations/me status = %d, want 200, body = %s", recMe.Code, recMe.Body.String())
	}

	rows = f.auditLogFor(t, "invitation", invitation.ID)
	if len(rows) != 2 {
		t.Fatalf("invitation audit rows after accept = %d, want 2: %+v", len(rows), rows)
	}
	acceptRow := rows[1]
	if acceptRow.ChangeType != "update" {
		t.Fatalf("accept audit change_type = %q, want update", acceptRow.ChangeType)
	}
	if acceptRow.ActorUserID != inviteeUserID {
		t.Fatalf("accept audit actor_user_id = %q, want %q (accepting user)", acceptRow.ActorUserID, inviteeUserID)
	}
	if len(acceptRow.ChangedFields) != 1 || acceptRow.ChangedFields[0] != "status" {
		t.Fatalf("accept audit changed_fields = %v, want [status]", acceptRow.ChangedFields)
	}
	var acceptChange map[string]any
	if err := json.Unmarshal(acceptRow.Change, &acceptChange); err != nil {
		t.Fatalf("unmarshal accept change: %v", err)
	}
	statusDelta, ok := acceptChange["status"].(map[string]any)
	if !ok {
		t.Fatalf("accept change[status] = %#v, want a {from,to} object", acceptChange["status"])
	}
	if statusDelta["from"] != "pending" || statusDelta["to"] != "accepted" {
		t.Fatalf("accept change[status] = %+v, want from=pending to=accepted", statusDelta)
	}

	// Acceptance also creates a new membership — its own create row, same
	// transaction (mirrors organization creation's org+membership pair).
	var membershipRows []auditRow
	dbRows, err := f.pool.Query(context.Background(),
		`SELECT entity_type, change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
		 FROM organizations.audit_log
		 WHERE organization_id = $1 AND entity_type = 'membership'
		 ORDER BY recorded_at, id`, orgID)
	if err != nil {
		t.Fatalf("query membership audit_log: %v", err)
	}
	defer dbRows.Close()
	for dbRows.Next() {
		var (
			a       auditRow
			actorID uuid.UUID
		)
		if err := dbRows.Scan(&a.EntityType, &a.ChangeType, &actorID, &a.OccurredAt, &a.RecordedAt, &a.ChangedFields, &a.Change); err != nil {
			t.Fatalf("scan membership audit row: %v", err)
		}
		a.ActorUserID = actorID.String()
		membershipRows = append(membershipRows, a)
	}
	// Two memberships exist under this org: the admin's (from org creation)
	// and the invitee's (from this acceptance) — both create rows.
	if len(membershipRows) != 2 {
		t.Fatalf("membership audit rows = %d, want 2 (admin's + invitee's): %+v", len(membershipRows), membershipRows)
	}
	foundInvitee := false
	for _, m := range membershipRows {
		if m.ActorUserID == inviteeUserID {
			foundInvitee = true
			if m.ChangeType != "create" {
				t.Errorf("invitee membership audit change_type = %q, want create", m.ChangeType)
			}
		}
	}
	if !foundInvitee {
		t.Fatalf("membership audit rows = %+v, want one attributed to the invitee %s", membershipRows, inviteeUserID)
	}
}

// TestRevokeInvitation_History_WritesOneUpdateRow covers the revoke path:
// exactly one update row (pending -> revoked), actor = the revoking admin.
func TestRevokeInvitation_History_WritesOneUpdateRow(t *testing.T) {
	adminSub := "e9999999-3333-4999-8999-3333333339e9"
	adminUserID := "a0000000-0000-7000-8000-0000000009e9"
	f := newOrgFixture(t, map[string]string{adminSub: adminUserID})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-0000000009e9"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recInvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": "revoke-history@example.com"})
	if recInvite.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", recInvite.Code, recInvite.Body.String())
	}
	var invitation api.InvitationResponse
	if err := json.Unmarshal(recInvite.Body.Bytes(), &invitation); err != nil {
		t.Fatalf("decode: %v", err)
	}

	recRevoke := f.do(t, http.MethodDelete, "/v1/organizations/"+orgID+"/invitations/"+invitation.ID, adminBearer, nil)
	if recRevoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204, body = %s", recRevoke.Code, recRevoke.Body.String())
	}

	rows := f.auditLogFor(t, "invitation", invitation.ID)
	if len(rows) != 2 {
		t.Fatalf("invitation audit rows after revoke = %d, want 2 (create, revoke): %+v", len(rows), rows)
	}
	revokeRow := rows[1]
	if revokeRow.ChangeType != "update" {
		t.Fatalf("revoke audit change_type = %q, want update", revokeRow.ChangeType)
	}
	if revokeRow.ActorUserID != adminUserID {
		t.Fatalf("revoke audit actor_user_id = %q, want %q (revoking admin)", revokeRow.ActorUserID, adminUserID)
	}
	var revokeChange map[string]any
	if err := json.Unmarshal(revokeRow.Change, &revokeChange); err != nil {
		t.Fatalf("unmarshal revoke change: %v", err)
	}
	statusDelta, ok := revokeChange["status"].(map[string]any)
	if !ok {
		t.Fatalf("revoke change[status] = %#v, want a {from,to} object", revokeChange["status"])
	}
	if statusDelta["from"] != "pending" || statusDelta["to"] != "revoked" {
		t.Fatalf("revoke change[status] = %+v, want from=pending to=revoked", statusDelta)
	}
}

// TestInvitations_History_ChangePayloadNeverEmbedsActorPersonalData is
// #165's pseudonymity contract test (history.md §7.3) for invitations: the
// invitee's OWN email legitimately appears (it is the invitation's own
// subject field, data-model.md §3 — see audit.go's invitationFields doc),
// but the ACTOR's identity (the inviting/revoking/accepting admin or user)
// must never be denormalized into the payload as a labeled name/email field
// — it lives solely in actor_user_id.
func TestInvitations_History_ChangePayloadNeverEmbedsActorPersonalData(t *testing.T) {
	adminSub := "fa111111-4444-4111-8111-4444444114fa"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-00000000fa11"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-00000000fa11"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recInvite := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": "subject@example.com"})
	if recInvite.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", recInvite.Code, recInvite.Body.String())
	}
	var invitation api.InvitationResponse
	if err := json.Unmarshal(recInvite.Body.Bytes(), &invitation); err != nil {
		t.Fatalf("decode: %v", err)
	}

	for _, row := range f.auditLogFor(t, "invitation", invitation.ID) {
		var decoded map[string]any
		if err := json.Unmarshal(row.Change, &decoded); err != nil {
			t.Fatalf("change payload is not a JSON object: %s", string(row.Change))
		}
		if _, ok := decoded["actor_name"]; ok {
			t.Fatalf("change payload embeds an actor_name field: %s", string(row.Change))
		}
		if _, ok := decoded["actor_email"]; ok {
			t.Fatalf("change payload embeds an actor_email field: %s", string(row.Change))
		}
		// invited_by must stay a soft ID (UUID string), never resolved to a
		// name — assert its value parses as a UUID.
		if ib, ok := decoded["invited_by"]; ok {
			s, isString := ib.(string)
			if !isString {
				t.Fatalf("change payload invited_by = %#v, want a UUID string", ib)
			}
			if _, err := uuid.Parse(s); err != nil {
				t.Fatalf("change payload invited_by = %q, want a valid UUID (soft ID, not a name): %v", s, err)
			}
		}
	}
}

// TestCreateInvitation_InvalidRole_Returns422 covers the invalid-role
// validation branch (MEDIUM review finding: previously untested).
func TestCreateInvitation_InvalidRole_Returns422(t *testing.T) {
	adminSub := "d1d1d1d1-d1d1-4d1d-8d1d-d1d1d1d1d1d1"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000d1"})
	adminBearer := f.token(t, adminSub)

	orgID := "c4000000-0000-7000-8000-000000000001"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "someone@example.com", "role": "superadmin",
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
	var p struct {
		Errors []struct {
			Field string `json:"field"`
			Code  string `json:"code"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	found := false
	for _, e := range p.Errors {
		if e.Field == "role" && e.Code == "invalid" {
			found = true
		}
	}
	if !found {
		t.Errorf("errors = %+v, want an invalid error on role", p.Errors)
	}
}

// TestCreateInvitation_EmailTooLong_Returns422 covers the email length cap
// validation branch (MEDIUM review finding: previously untested).
func TestCreateInvitation_EmailTooLong_Returns422(t *testing.T) {
	adminSub := "d2d2d2d2-d2d2-4d2d-8d2d-d2d2d2d2d2d2"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000d2"})
	adminBearer := f.token(t, adminSub)

	orgID := "c4000000-0000-7000-8000-000000000002"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	longLocal := strings.Repeat("a", 310) // local part alone already exceeds maxEmailLength=320 once @example.com is appended
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": longLocal + "@example.com",
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
	var p struct {
		Errors []struct {
			Field string `json:"field"`
			Code  string `json:"code"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	found := false
	for _, e := range p.Errors {
		if e.Field == "email" && e.Code == "invalid" {
			found = true
		}
	}
	if !found {
		t.Errorf("errors = %+v, want an invalid error on email", p.Errors)
	}
}

// TestListInvitations_Pagination_NextCursor covers the next_cursor response
// path (MEDIUM review finding: previously untested): with more rows than the
// requested limit, the first page carries a non-nil next_cursor, and
// following it returns the remaining row with no further cursor.
func TestListInvitations_Pagination_NextCursor(t *testing.T) {
	adminSub := "d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000d3"})
	adminBearer := f.token(t, adminSub)

	orgID := "c4000000-0000-7000-8000-000000000003"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	emails := []string{"page-a@example.com", "page-b@example.com", "page-c@example.com"}
	for _, email := range emails {
		if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{"email": email}); rec.Code != http.StatusCreated {
			t.Fatalf("invite %s status = %d, want 201, body = %s", email, rec.Code, rec.Body.String())
		}
	}

	recPage1 := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations?limit=2", adminBearer, nil)
	if recPage1.Code != http.StatusOK {
		t.Fatalf("page 1 status = %d, want 200, body = %s", recPage1.Code, recPage1.Body.String())
	}
	var page1 struct {
		Data []api.InvitationResponse `json:"data"`
		Page struct {
			NextCursor *string `json:"next_cursor"`
			Limit      int     `json:"limit"`
		} `json:"page"`
	}
	if err := json.Unmarshal(recPage1.Body.Bytes(), &page1); err != nil {
		t.Fatalf("decode page 1: %v", err)
	}
	if len(page1.Data) != 2 {
		t.Fatalf("page 1 data = %+v, want 2 rows", page1.Data)
	}
	if page1.Page.NextCursor == nil {
		t.Fatalf("page 1 next_cursor = nil, want a cursor (3 rows exist, limit=2)")
	}
	if page1.Page.Limit != 2 {
		t.Errorf("page 1 limit = %d, want 2", page1.Page.Limit)
	}

	recPage2 := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations?limit=2&cursor="+*page1.Page.NextCursor, adminBearer, nil)
	if recPage2.Code != http.StatusOK {
		t.Fatalf("page 2 status = %d, want 200, body = %s", recPage2.Code, recPage2.Body.String())
	}
	var page2 struct {
		Data []api.InvitationResponse `json:"data"`
		Page struct {
			NextCursor *string `json:"next_cursor"`
		} `json:"page"`
	}
	if err := json.Unmarshal(recPage2.Body.Bytes(), &page2); err != nil {
		t.Fatalf("decode page 2: %v", err)
	}
	if len(page2.Data) != 1 {
		t.Fatalf("page 2 data = %+v, want 1 remaining row", page2.Data)
	}
	if page2.Page.NextCursor != nil {
		t.Errorf("page 2 next_cursor = %v, want nil (no more rows)", *page2.Page.NextCursor)
	}
}

// TestListInvitations_InvalidLimit_Returns422 covers the parsePage
// consistency fix (MEDIUM review finding): a non-numeric or non-positive
// limit used to silently fall back to the default instead of 422'ing, unlike
// an equally malformed cursor. Both must now behave the same way.
func TestListInvitations_InvalidLimit_Returns422(t *testing.T) {
	adminSub := "d4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000d4"})
	adminBearer := f.token(t, adminSub)

	orgID := "c4000000-0000-7000-8000-000000000004"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Org"}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	for _, limit := range []string{"not-a-number", "0", "-1"} {
		rec := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations?limit="+limit, adminBearer, nil)
		if rec.Code != http.StatusUnprocessableEntity {
			t.Errorf("limit=%q status = %d, want 422, body = %s", limit, rec.Code, rec.Body.String())
		}
	}
}
