package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
)

// addAcceptedMember invites memberEmail into orgID as `role` and drives the
// accept-on-login path so the member ends up active — the same invite+accept
// sequence the invitation tests use, factored out for the lifecycle tests that
// need a second, non-creator member to act on. Returns nothing; the caller
// already knows the member's ids/bearer.
func addAcceptedMember(t *testing.T, f *orgFixture, adminBearer, memberBearer, orgID, memberEmail, role string) {
	t.Helper()
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": memberEmail, "role": role,
	}); rec.Code != http.StatusCreated {
		t.Fatalf("invite %s status = %d, want 201, body = %s", memberEmail, rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", memberBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("accept-on-login for %s status = %d, want 200, body = %s", memberEmail, rec.Code, rec.Body.String())
	}
}

// membershipID looks up a membership row's primary key by (org, user) —
// history rows are keyed by that id (not the user_id), and no response body
// exposes it, so the audit-trail assertions query for it directly (mirrors the
// invitation tests' own membership-by-org audit queries).
func membershipID(t *testing.T, f *orgFixture, orgID, userID string) string {
	t.Helper()
	var id string
	if err := f.pool.QueryRow(context.Background(),
		`SELECT id FROM organizations.memberships WHERE organization_id = $1 AND user_id = $2`,
		orgID, userID).Scan(&id); err != nil {
		t.Fatalf("look up membership id for user %s: %v", userID, err)
	}
	return id
}

// TestMemberLifecycle_PromoteDemoteRemove is the #290 happy path: an admin
// promotes a member to admin, demotes them back to user, then removes them —
// each reflected in the admin member list — and the removed member immediately
// loses access on their next request (FR-TEN-2, NFR-ROL-1). It also asserts the
// history trail: the role changes and the removal each write one membership
// audit update row attributed to the acting admin (FR-HIS-1).
func TestMemberLifecycle_PromoteDemoteRemove(t *testing.T) {
	adminSub := "a0000001-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-000000000a01"
	memberSub := "a0000002-2222-4222-8222-222222222222"
	memberUserID := "a0000000-0000-7000-8000-000000000a02"
	memberEmail := "member@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:  {UserID: adminUserID},
			memberSub: {UserID: memberUserID, Email: memberEmail},
		},
		map[string]tokenClaim{memberSub: {Email: memberEmail, EmailVerified: true}},
	)
	adminBearer := f.token(t, adminSub)
	memberBearer := f.token(t, memberSub)

	orgID := "b0000000-0000-7000-8000-000000000a01"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Lifecycle Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	addAcceptedMember(t, f, adminBearer, memberBearer, orgID, memberEmail, "user")

	memberPath := "/v1/organizations/" + orgID + "/members/" + memberUserID

	// Promote user -> admin.
	recPromote := f.do(t, http.MethodPatch, memberPath, adminBearer, map[string]string{"role": "admin"})
	if recPromote.Code != http.StatusOK {
		t.Fatalf("promote status = %d, want 200, body = %s", recPromote.Code, recPromote.Body.String())
	}
	var promoted api.MemberResponse
	if err := json.Unmarshal(recPromote.Body.Bytes(), &promoted); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if promoted.UserID != memberUserID || promoted.Role != "admin" || promoted.Status != "active" {
		t.Errorf("promoted member = %+v, want user_id=%s role=admin status=active", promoted, memberUserID)
	}

	// Demote admin -> user (allowed: the creator admin still remains).
	recDemote := f.do(t, http.MethodPatch, memberPath, adminBearer, map[string]string{"role": "user"})
	if recDemote.Code != http.StatusOK {
		t.Fatalf("demote status = %d, want 200, body = %s", recDemote.Code, recDemote.Body.String())
	}
	var demoted api.MemberResponse
	if err := json.Unmarshal(recDemote.Body.Bytes(), &demoted); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if demoted.Role != "user" {
		t.Errorf("demoted role = %q, want user", demoted.Role)
	}

	// Remove the member.
	if rec := f.do(t, http.MethodDelete, memberPath, adminBearer, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("remove status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}

	// Enforced on the removed member's very next request: no active membership.
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", memberBearer, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("removed member GET /organizations/me status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}

	// The admin member list now shows only the creator; the removed member is
	// excluded (ListMembers filters status != 'removed').
	recList := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/members", adminBearer, nil)
	if recList.Code != http.StatusOK {
		t.Fatalf("list members status = %d, want 200, body = %s", recList.Code, recList.Body.String())
	}
	var members struct {
		Data []api.MemberResponse `json:"data"`
	}
	if err := json.Unmarshal(recList.Body.Bytes(), &members); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, m := range members.Data {
		if m.UserID == memberUserID {
			t.Errorf("removed member %s still present in member list: %+v", memberUserID, members.Data)
		}
	}

	// History (FR-HIS-1): the member's audit trail is create(accept) then three
	// update rows — role admin, role user, status removed — each by the admin.
	rows := f.auditLogFor(t, "membership", membershipID(t, f, orgID, memberUserID))
	var updates []auditRow
	for _, r := range rows {
		if r.ChangeType == "update" {
			updates = append(updates, r)
		}
	}
	if len(updates) != 3 {
		t.Fatalf("membership update audit rows = %d, want 3 (promote, demote, remove): %+v", len(updates), updates)
	}
	for _, r := range updates {
		if r.ActorUserID != adminUserID {
			t.Errorf("update audit actor_user_id = %q, want %q (acting admin)", r.ActorUserID, adminUserID)
		}
	}
	assertFieldChange(t, updates[0], "role", "user", "admin")
	assertFieldChange(t, updates[1], "role", "admin", "user")
	assertFieldChange(t, updates[2], "status", "active", "removed")
}

// assertFieldChange asserts a single-field update audit row's changed_fields
// and {from,to} delta (history.md §3), shared by the lifecycle history checks.
func assertFieldChange(t *testing.T, row auditRow, field, from, to string) {
	t.Helper()
	if len(row.ChangedFields) != 1 || row.ChangedFields[0] != field {
		t.Fatalf("changed_fields = %v, want [%s]", row.ChangedFields, field)
	}
	var change map[string]any
	if err := json.Unmarshal(row.Change, &change); err != nil {
		t.Fatalf("unmarshal change: %v", err)
	}
	delta, ok := change[field].(map[string]any)
	if !ok {
		t.Fatalf("change[%s] = %#v, want a {from,to} object", field, change[field])
	}
	if delta["from"] != from || delta["to"] != to {
		t.Errorf("change[%s] = %+v, want from=%s to=%s", field, delta, from, to)
	}
}

// TestMemberLifecycle_LastAdminGuard covers D-3's last-admin guard: in an org
// whose only admin is the caller, neither removing nor demoting that admin is
// allowed (both 409), so the org can never be left without an admin. The admin
// remains active and admin after each rejected attempt.
func TestMemberLifecycle_LastAdminGuard(t *testing.T) {
	adminSub := "a0000003-3333-4333-8333-333333333333"
	adminUserID := "a0000000-0000-7000-8000-000000000a03"
	f := newOrgFixture(t, map[string]string{adminSub: adminUserID})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000a03"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Solo Admin Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	selfPath := "/v1/organizations/" + orgID + "/members/" + adminUserID

	// Demote self (last admin) -> 409.
	if rec := f.do(t, http.MethodPatch, selfPath, adminBearer, map[string]string{"role": "user"}); rec.Code != http.StatusConflict {
		t.Fatalf("demote last admin status = %d, want 409, body = %s", rec.Code, rec.Body.String())
	}
	// Remove self (last admin) -> 409.
	if rec := f.do(t, http.MethodDelete, selfPath, adminBearer, nil); rec.Code != http.StatusConflict {
		t.Fatalf("remove last admin status = %d, want 409, body = %s", rec.Code, rec.Body.String())
	}

	// The admin is untouched — still an active admin, still resolves.
	recMe := f.do(t, http.MethodGet, "/v1/organizations/me", adminBearer, nil)
	if recMe.Code != http.StatusOK {
		t.Fatalf("admin GET /organizations/me status = %d, want 200, body = %s", recMe.Code, recMe.Body.String())
	}
	var me api.OrganizationResponse
	if err := json.Unmarshal(recMe.Body.Bytes(), &me); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if me.Role != "admin" {
		t.Errorf("admin role after rejected self-remove/demote = %q, want admin", me.Role)
	}

	// No membership audit update row was written by either rejected attempt.
	rows := f.auditLogFor(t, "membership", membershipID(t, f, orgID, adminUserID))
	for _, r := range rows {
		if r.ChangeType == "update" {
			t.Errorf("unexpected membership update audit row after rejected guarded ops: %+v", r)
		}
	}
}

// TestMemberLifecycle_SecondAdminUnblocksRemoval is the guard's positive
// counterpart: once a second admin exists, the (former only) admin can be
// removed — the guard blocks the *last* admin, not any admin.
func TestMemberLifecycle_SecondAdminUnblocksRemoval(t *testing.T) {
	adminSub := "a0000004-4444-4444-8444-444444444444"
	adminUserID := "a0000000-0000-7000-8000-000000000a04"
	secondSub := "a0000005-5555-4555-8555-555555555555"
	secondUserID := "a0000000-0000-7000-8000-000000000a05"
	secondEmail := "second-admin@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:  {UserID: adminUserID},
			secondSub: {UserID: secondUserID, Email: secondEmail},
		},
		map[string]tokenClaim{secondSub: {Email: secondEmail, EmailVerified: true}},
	)
	adminBearer := f.token(t, adminSub)
	secondBearer := f.token(t, secondSub)

	orgID := "b0000000-0000-7000-8000-000000000a04"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Two Admins Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	// Second member joins as an admin directly (invited at role=admin).
	addAcceptedMember(t, f, adminBearer, secondBearer, orgID, secondEmail, "admin")

	// Now the creator admin can be removed by the second admin (two admins exist).
	if rec := f.do(t, http.MethodDelete, "/v1/organizations/"+orgID+"/members/"+adminUserID, secondBearer, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("remove non-last admin status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}
	// The removed creator loses access; the second admin still resolves.
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", adminBearer, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("removed creator GET /organizations/me status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", secondBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("remaining admin GET /organizations/me status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
}

// TestMemberLifecycle_Authz covers the admin-only + org-scoped rules
// (auth.md §5.3, ADR-0002): a plain member cannot remove or change roles (403),
// and a caller from another org addressing this org's member path gets 404,
// never 403 (the path never widens scope).
func TestMemberLifecycle_Authz(t *testing.T) {
	adminSub := "a0000006-6666-4666-8666-666666666666"
	adminUserID := "a0000000-0000-7000-8000-000000000a06"
	memberSub := "a0000007-7777-4777-8777-777777777777"
	memberUserID := "a0000000-0000-7000-8000-000000000a07"
	memberEmail := "plain@example.com"
	outsiderSub := "a0000008-8888-4888-8888-888888888888"
	outsiderUserID := "a0000000-0000-7000-8000-000000000a08"
	outsiderEmail := "outsider@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:    {UserID: adminUserID},
			memberSub:   {UserID: memberUserID, Email: memberEmail},
			outsiderSub: {UserID: outsiderUserID, Email: outsiderEmail},
		},
		map[string]tokenClaim{
			memberSub:   {Email: memberEmail, EmailVerified: true},
			outsiderSub: {Email: outsiderEmail, EmailVerified: true},
		},
	)
	adminBearer := f.token(t, adminSub)
	memberBearer := f.token(t, memberSub)
	outsiderBearer := f.token(t, outsiderSub)

	orgID := "b0000000-0000-7000-8000-000000000a06"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Authz Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	addAcceptedMember(t, f, adminBearer, memberBearer, orgID, memberEmail, "user")

	// A second org for the outsider, so they are a valid caller of *their* org.
	outsiderOrg := "b0000000-0000-7000-8000-000000000a09"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", outsiderBearer, map[string]string{"id": outsiderOrg, "name": "Outsider Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create outsider org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	adminPath := "/v1/organizations/" + orgID + "/members/" + adminUserID

	// Non-admin member cannot change roles or remove -> 403.
	if rec := f.do(t, http.MethodPatch, adminPath, memberBearer, map[string]string{"role": "user"}); rec.Code != http.StatusForbidden {
		t.Errorf("non-admin PATCH role status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, adminPath, memberBearer, nil); rec.Code != http.StatusForbidden {
		t.Errorf("non-admin DELETE member status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}

	// Cross-org: the outsider (admin of their own org) addressing THIS org's
	// member path is 404, never 403 (ADR-0002 — never confirms another org).
	if rec := f.do(t, http.MethodPatch, adminPath, outsiderBearer, map[string]string{"role": "user"}); rec.Code != http.StatusNotFound {
		t.Errorf("cross-org PATCH status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, adminPath, outsiderBearer, nil); rec.Code != http.StatusNotFound {
		t.Errorf("cross-org DELETE status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestMemberLifecycle_Validation covers input/edge validation: an invalid role
// is 422, a malformed member id is 404, a well-formed but non-member id is 404,
// and removing an already-removed member is 404 (idempotency).
func TestMemberLifecycle_Validation(t *testing.T) {
	adminSub := "a000000a-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	adminUserID := "a0000000-0000-7000-8000-000000000a0a"
	memberSub := "a000000b-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	memberUserID := "a0000000-0000-7000-8000-000000000a0b"
	memberEmail := "victim@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:  {UserID: adminUserID},
			memberSub: {UserID: memberUserID, Email: memberEmail},
		},
		map[string]tokenClaim{memberSub: {Email: memberEmail, EmailVerified: true}},
	)
	adminBearer := f.token(t, adminSub)
	memberBearer := f.token(t, memberSub)

	orgID := "b0000000-0000-7000-8000-000000000a0a"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Validation Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	addAcceptedMember(t, f, adminBearer, memberBearer, orgID, memberEmail, "user")
	base := "/v1/organizations/" + orgID + "/members/"

	// Invalid role -> 422 with a field error on role.
	rec := f.do(t, http.MethodPatch, base+memberUserID, adminBearer, map[string]string{"role": "superadmin"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("invalid role status = %d, want 422, body = %s", rec.Code, rec.Body.String())
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
	foundRole := false
	for _, e := range p.Errors {
		if e.Field == "role" && e.Code == "invalid" {
			foundRole = true
		}
	}
	if !foundRole {
		t.Errorf("errors = %+v, want an invalid error on role", p.Errors)
	}

	// Malformed member id -> 404.
	if rec := f.do(t, http.MethodDelete, base+"not-a-uuid", adminBearer, nil); rec.Code != http.StatusNotFound {
		t.Errorf("malformed member id status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
	// Well-formed but non-member id -> 404.
	if rec := f.do(t, http.MethodDelete, base+"a0000000-0000-7000-8000-0000000000ff", adminBearer, nil); rec.Code != http.StatusNotFound {
		t.Errorf("non-member id status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}

	// Remove the member, then removing again is 404 (idempotency — no active row).
	if rec := f.do(t, http.MethodDelete, base+memberUserID, adminBearer, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("first remove status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodDelete, base+memberUserID, adminBearer, nil); rec.Code != http.StatusNotFound {
		t.Errorf("second remove status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestMemberLifecycle_RoleChangeConformsToOpenAPIContract validates the real
// PATCH 200 body against contracts/openapi/organizations.openapi.yaml (#153
// boundary-testing convention) — the Member schema the change-role response
// must satisfy.
func TestMemberLifecycle_RoleChangeConformsToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/organizations.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	adminSub := "a000000c-cccc-4ccc-8ccc-cccccccccccc"
	adminUserID := "a0000000-0000-7000-8000-000000000a0c"
	memberSub := "a000000d-dddd-4ddd-8ddd-dddddddddddd"
	memberUserID := "a0000000-0000-7000-8000-000000000a0d"
	memberEmail := "contract@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:  {UserID: adminUserID},
			memberSub: {UserID: memberUserID, Email: memberEmail},
		},
		map[string]tokenClaim{memberSub: {Email: memberEmail, EmailVerified: true}},
	)
	adminBearer := f.token(t, adminSub)
	memberBearer := f.token(t, memberSub)

	orgID := "b0000000-0000-7000-8000-000000000a0c"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Contract Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	addAcceptedMember(t, f, adminBearer, memberBearer, orgID, memberEmail, "user")

	rec := f.do(t, http.MethodPatch, "/v1/organizations/"+orgID+"/members/"+memberUserID, adminBearer, map[string]string{"role": "admin"})
	if rec.Code != http.StatusOK {
		t.Fatalf("change role status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPatch, "/v1/organizations/"+orgID+"/members/"+memberUserID, http.StatusOK, rec.Body.Bytes())
}

// TestMemberLifecycle_ConcurrentLastAdminRemoval_Serializes is the last-admin
// guard's race regression test (code-review MEDIUM #3, D-3). An org with exactly
// two admins gets two concurrent removals — each admin removing the other —
// fired from goroutines released by a shared start channel so they race as
// closely as the real HTTP/DB round trips allow, against a real Postgres
// container (not a mock). Without the per-org serialization lock
// (LockOrganizationForUpdate), both transactions could read "two admins", both
// pass the guard on a snapshot that doesn't yet see the other's uncommitted
// removal, and both commit — leaving the org with ZERO admins. With the lock the
// two transactions serialize on the org row, so exactly one removal succeeds
// (204) and the other is correctly rejected, and the org is left with exactly
// one active admin.
//
// The rejected request may be 404 or 409, both correct: whichever actor loses
// the race has, by the time its own request's admin check runs, either already
// been removed by the winner (so it is no longer an active admin → 404 at the
// auth guard) or still active but now facing a one-admin org (→ 409 at the
// last-admin guard). The deterministic 409 path is covered by
// TestMemberLifecycle_LastAdminGuard; what this test pins is the invariant that
// the race can never drop the admin count to zero.
func TestMemberLifecycle_ConcurrentLastAdminRemoval_Serializes(t *testing.T) {
	adminSub := "a000000e-eeee-4eee-8eee-eeeeeeeeeeee"
	adminUserID := "a0000000-0000-7000-8000-000000000a0e"
	secondSub := "a000000f-ffff-4fff-8fff-ffffffffffff"
	secondUserID := "a0000000-0000-7000-8000-000000000a0f"
	secondEmail := "second@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub:  {UserID: adminUserID},
			secondSub: {UserID: secondUserID, Email: secondEmail},
		},
		map[string]tokenClaim{secondSub: {Email: secondEmail, EmailVerified: true}},
	)
	adminBearer := f.token(t, adminSub)
	secondBearer := f.token(t, secondSub)

	orgID := "b0000000-0000-7000-8000-000000000a0e"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{"id": orgID, "name": "Race Co."}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	// Two admins now exist: the creator and the invited second admin.
	addAcceptedMember(t, f, adminBearer, secondBearer, orgID, secondEmail, "admin")

	// Each admin's request removes the OTHER admin, concurrently. Both use their
	// own bearer (both are admins of this org) and target a distinct member.
	remove := func(bearer, targetUserID string) int {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodDelete, "/v1/organizations/"+orgID+"/members/"+targetUserID, nil)
		req.Header.Set("Authorization", bearer)
		f.srv.Router().ServeHTTP(rec, req)
		return rec.Code
	}
	targets := []struct{ bearer, target string }{
		{adminBearer, secondUserID},
		{secondBearer, adminUserID},
	}

	start := make(chan struct{})
	var wg sync.WaitGroup
	codes := make([]int, len(targets))
	for i, tg := range targets {
		wg.Add(1)
		go func(i int, bearer, target string) {
			defer wg.Done()
			<-start
			codes[i] = remove(bearer, target)
		}(i, tg.bearer, tg.target)
	}
	close(start)
	wg.Wait()

	var removed, rejected int
	for _, code := range codes {
		switch code {
		case http.StatusNoContent:
			removed++
		case http.StatusConflict, http.StatusNotFound:
			rejected++
		default:
			t.Errorf("unexpected status %d among concurrent removals %v", code, codes)
		}
	}
	if removed != 1 || rejected != 1 {
		t.Fatalf("concurrent last-admin removals = %v, want exactly one 204 and one rejection (409 or 404) — LockOrganizationForUpdate serialization", codes)
	}

	// The org still has exactly one active admin: the race never dropped the
	// count to zero (the whole point of the per-org serialization lock).
	var activeAdmins int
	if err := f.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM organizations.memberships WHERE organization_id = $1 AND role = 'admin' AND status = 'active'`,
		orgID).Scan(&activeAdmins); err != nil {
		t.Fatalf("count active admins: %v", err)
	}
	if activeAdmins != 1 {
		t.Fatalf("active admins after concurrent removals = %d, want exactly 1", activeAdmins)
	}
}
