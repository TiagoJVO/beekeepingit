package main

// Integration tests for PATCH /organizations/{orgId} (#289, FR-ONB-2,
// FR-TEN-2, FR-HIS-1, NFR-ROL-1, NFR-SEC-1). They exercise the full authn +
// org-resolve chain against a containerized Postgres, reusing the fixture
// helpers in organizations_test.go (newOrgFixture*, f.do, f.token,
// f.auditLogFor). The If-Match/ETag round-trip needs a header the shared f.do
// helper doesn't set, so requests that carry one are built via doWithHeaders
// below.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
)

// doWithHeaders is f.do plus arbitrary extra request headers (e.g. If-Match) —
// the shared f.do only sets Authorization. Mirrors f.do's marshal/serve shape.
func (f *orgFixture) doWithHeaders(t *testing.T, method, path, bearer string, headers map[string]string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		r = bytes.NewReader(b)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, r)
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	f.srv.Router().ServeHTTP(rec, req)
	return rec
}

// newAdminOrg creates an org with the given admin and returns the org id plus
// the ETag the create response carried (the value a PATCH echoes back in
// If-Match). Shared setup for the update tests below.
func newAdminOrg(t *testing.T, f *orgFixture, adminBearer, orgID, name, address string) string {
	t.Helper()
	rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": name, "address": address,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	etag := rec.Header().Get("ETag")
	if etag == "" {
		t.Fatalf("create org response missing ETag header (needed for the If-Match round-trip)")
	}
	return etag
}

// TestUpdateOrganization_AdminUpdatesFields is the core AC: an admin edits
// their org's name and address with a matching If-Match; the response is 200
// with the new values and a fresh ETag, and the change is recorded in
// entity history with the admin as actor (FR-HIS-1).
func TestUpdateOrganization_AdminUpdatesFields(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	f := newOrgFixture(t, map[string]string{adminSub: adminUserID})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000201"
	etag := newAdminOrg(t, f, adminBearer, orgID, "Old Name", "Old Address")

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]string{"name": "New Name", "address": "New Address"})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.Name != "New Name" || org.Address != "New Address" {
		t.Errorf("updated org = %+v, want name=New Name address=New Address", org)
	}
	if org.Role != "admin" {
		t.Errorf("role = %q, want admin (caller's own role, #172)", org.Role)
	}
	newETag := rec.Header().Get("ETag")
	if newETag == "" || newETag == etag {
		t.Errorf("PATCH ETag = %q, want a fresh non-empty value distinct from %q", newETag, etag)
	}

	// The edit is visible on a subsequent read, with the same fresh ETag.
	recGet := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, adminBearer, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200, body = %s", recGet.Code, recGet.Body.String())
	}
	if got := recGet.Header().Get("ETag"); got != newETag {
		t.Errorf("GET ETag = %q, want %q (matches the last write)", got, newETag)
	}

	// History (FR-HIS-1): the create row plus one update row attributed to the
	// admin, whose changed_fields cover the edited columns.
	rows := f.auditLogFor(t, "organization", orgID)
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + update)", len(rows))
	}
	upd := rows[1]
	if upd.ChangeType != "update" {
		t.Errorf("second audit row change_type = %q, want update", upd.ChangeType)
	}
	if upd.ActorUserID != adminUserID {
		t.Errorf("update actor = %q, want %q (the admin)", upd.ActorUserID, adminUserID)
	}
	if upd.OccurredAt.IsZero() {
		t.Errorf("update occurred_at is zero, want a timestamp (FR-HIS-1)")
	}
	changed := map[string]bool{}
	for _, c := range upd.ChangedFields {
		changed[c] = true
	}
	if !changed["name"] || !changed["address"] {
		t.Errorf("changed_fields = %v, want name and address", upd.ChangedFields)
	}
}

// TestUpdateOrganization_PartialUpdate covers a single-field PATCH: only name
// is sent, address is left untouched (minProperties:1 is satisfied by one key).
func TestUpdateOrganization_PartialUpdate(t *testing.T) {
	adminSub := "a2222222-2222-4222-8222-222222222222"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000a2"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000202"
	etag := newAdminOrg(t, f, adminBearer, orgID, "Keep Name", "Keep Address")

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]string{"name": "Renamed"})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.Name != "Renamed" {
		t.Errorf("name = %q, want Renamed", org.Name)
	}
	if org.Address != "Keep Address" {
		t.Errorf("address = %q, want Keep Address (untouched by a name-only PATCH)", org.Address)
	}
}

// TestUpdateOrganization_AddressNullClears covers the OrganizationUpdate
// schema's nullable address: an explicit JSON null clears it to "" (the column
// is NOT NULL DEFAULT ”), distinct from omitting the key.
func TestUpdateOrganization_AddressNullClears(t *testing.T) {
	adminSub := "a3333333-3333-4333-8333-333333333333"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000a3"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000203"
	etag := newAdminOrg(t, f, adminBearer, orgID, "Org", "Some Address")

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]any{"address": nil})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.Address != "" {
		t.Errorf("address = %q, want empty (explicit null clears it)", org.Address)
	}
}

// TestUpdateOrganization_NoIfMatch_Succeeds asserts If-Match is optional
// (contract): a PATCH without it still applies.
func TestUpdateOrganization_NoIfMatch_Succeeds(t *testing.T) {
	adminSub := "a4444444-4444-4444-8444-444444444444"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000a4"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000204"
	newAdminOrg(t, f, adminBearer, orgID, "Org", "Addr")

	rec := f.do(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"name": "No If-Match Name"})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH without If-Match status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
}

// TestUpdateOrganization_StaleIfMatch_Returns409 covers optimistic concurrency
// (FR-TEN-2): a non-matching If-Match is rejected with 409 and makes no change.
func TestUpdateOrganization_StaleIfMatch_Returns409(t *testing.T) {
	adminSub := "a5555555-5555-4555-8555-555555555555"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000a5"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000205"
	newAdminOrg(t, f, adminBearer, orgID, "Original", "Original Addr")

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": `"stale-nonmatching"`},
		map[string]string{"name": "Should Not Apply"})
	if rec.Code != http.StatusConflict {
		t.Fatalf("PATCH status = %d, want 409, body = %s", rec.Code, rec.Body.String())
	}

	// No change was made.
	recGet := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, adminBearer, nil)
	var org api.OrganizationResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.Name != "Original" {
		t.Errorf("name = %q, want Original (stale write must not apply)", org.Name)
	}
	// Only the create row exists in history — no update was recorded.
	if rows := f.auditLogFor(t, "organization", orgID); len(rows) != 1 {
		t.Errorf("audit rows = %d, want 1 (create only; the rejected write recorded nothing)", len(rows))
	}
}

// TestUpdateOrganization_InvalidBody_Returns422_NoChange covers input
// validation (NFR-SEC-1): an empty name, and separately an empty body, are
// rejected with 422 and make no change.
func TestUpdateOrganization_InvalidBody_Returns422_NoChange(t *testing.T) {
	adminSub := "a6666666-6666-4666-8666-666666666666"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000a6"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000206"
	etag := newAdminOrg(t, f, adminBearer, orgID, "Valid", "Valid Addr")

	// Empty name (blank after trim) → 422.
	if rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]string{"name": "   "}); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("empty-name PATCH status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}

	// Empty body (no fields) → 422 (minProperties:1).
	if rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]any{}); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("empty-body PATCH status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}

	// The org is untouched by either rejected request.
	recGet := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, adminBearer, nil)
	var org api.OrganizationResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.Name != "Valid" || org.Address != "Valid Addr" {
		t.Errorf("org = %+v, want unchanged Valid/Valid Addr", org)
	}
}

// TestUpdateOrganization_NonAdminMember_Returns403 covers role enforcement
// (NFR-ROL-1, auth.md §5.3): a plain 'user' member of the org may not update
// it. The user member is provisioned via the accept-on-login path.
func TestUpdateOrganization_NonAdminMember_Returns403(t *testing.T) {
	adminSub := "a7777777-7777-4777-8777-777777777777"
	adminUserID := "a0000000-0000-7000-8000-0000000000a7"
	userSub := "b7777777-7777-4777-8777-777777777777"
	userUserID := "a0000000-0000-7000-8000-0000000000b7"
	userEmail := "member@example.com"

	f := newOrgFixtureWithEmailClaims(t,
		map[string]stubUser{
			adminSub: {UserID: adminUserID},
			userSub:  {UserID: userUserID, Email: userEmail},
		},
		map[string]tokenClaim{
			userSub: {Email: userEmail, EmailVerified: true},
		},
	)
	adminBearer := f.token(t, adminSub)
	userBearer := f.token(t, userSub)

	orgID := "b0000000-0000-7000-8000-000000000207"
	newAdminOrg(t, f, adminBearer, orgID, "Org", "Addr")

	// Admin invites the user (role user); the user joins on first /me poll.
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer,
		map[string]string{"email": userEmail, "role": "user"}); rec.Code != http.StatusCreated {
		t.Fatalf("invite status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	recMe := f.do(t, http.MethodGet, "/v1/organizations/me", userBearer, nil)
	if recMe.Code != http.StatusOK {
		t.Fatalf("accept-on-login status = %d, want 200, body = %s", recMe.Code, recMe.Body.String())
	}
	etag := recMe.Header().Get("ETag")

	// The user member is org-scoped correctly (so this is a 403 role rejection,
	// not a 404 scope rejection) but is not an admin → 403.
	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, userBearer,
		map[string]string{"If-Match": etag},
		map[string]string{"name": "Member Should Not Edit"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin PATCH status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}

	// No update was recorded.
	if rows := f.auditLogFor(t, "organization", orgID); len(rows) != 1 {
		t.Errorf("audit rows = %d, want 1 (create only)", len(rows))
	}
}

// TestUpdateOrganization_DifferentOrg_Returns404 covers cross-org scoping
// (FR-TEN-2, ADR-0002): an admin of org A patching org B's id gets 404 — the
// path never widens scope, and another org's existence is never revealed.
func TestUpdateOrganization_DifferentOrg_Returns404(t *testing.T) {
	adminASub := "a8888888-8888-4888-8888-888888888888"
	adminBSub := "b8888888-8888-4888-8888-888888888888"
	f := newOrgFixture(t, map[string]string{
		adminASub: "a0000000-0000-7000-8000-0000000000a8",
		adminBSub: "a0000000-0000-7000-8000-0000000000b8",
	})
	adminABearer := f.token(t, adminASub)
	adminBBearer := f.token(t, adminBSub)

	orgA := "b0000000-0000-7000-8000-0000000002a8"
	orgB := "b0000000-0000-7000-8000-0000000002b8"
	newAdminOrg(t, f, adminABearer, orgA, "Org A", "A")
	newAdminOrg(t, f, adminBBearer, orgB, "Org B", "B")

	// Admin A tries to edit org B → 404 (not 403), matching getOrganization.
	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgB, adminABearer,
		map[string]string{"If-Match": "*"},
		map[string]string{"name": "Cross-Org Edit"})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-org PATCH status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}

	// Org B is unchanged.
	recGet := f.do(t, http.MethodGet, "/v1/organizations/"+orgB, adminBBearer, nil)
	var org api.OrganizationResponse
	if err := json.Unmarshal(recGet.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.Name != "Org B" {
		t.Errorf("org B name = %q, want unchanged Org B", org.Name)
	}
}

// TestUpdateOrganization_NoMembership_Returns404 covers a caller with no active
// membership at all — resolveActiveMembership 404s ("no organization found for
// the caller"), the same signal the client's org-completion gate relies on.
func TestUpdateOrganization_NoMembership_Returns404(t *testing.T) {
	sub := "a9999999-9999-4999-8999-999999999999"
	f := newOrgFixture(t, map[string]string{sub: "a0000000-0000-7000-8000-0000000000a9"})
	bearer := f.token(t, sub)

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/b0000000-0000-7000-8000-0000000002a9", bearer,
		map[string]string{"If-Match": "*"},
		map[string]string{"name": "No Org"})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("no-membership PATCH status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestUpdateOrganization_Unauthenticated_Returns401 asserts PATCH requires a
// bearer token.
func TestUpdateOrganization_Unauthenticated_Returns401(t *testing.T) {
	f := newOrgFixture(t, nil)
	rec := f.do(t, http.MethodPatch, "/v1/organizations/b0000000-0000-7000-8000-0000000002aa", "",
		map[string]string{"name": "Nope"})
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

// TestUpdateOrganization_RegistrationNumber covers FR-AP-9's
// organization-level DEFAULT (#296): the beekeeper registration number the
// local authority issues (in Portugal, DGAV's `número de registo do
// apicultor`) is one value per beekeeper, so it lives here on the org — an
// apiary only ever carries an OVERRIDE
// (apiaries.apiaries.registration_number), for the case of an
// organization covering several beekeepers. Set, read back, and confirm the
// change is audited like any other org field edit (FR-HIS-1).
func TestUpdateOrganization_RegistrationNumber(t *testing.T) {
	adminSub := "a9111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000d1"
	f := newOrgFixture(t, map[string]string{adminSub: adminUserID})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000291"
	etag := newAdminOrg(t, f, adminBearer, orgID, "Apiários do Montargil", "Rua das Abelhas 1")

	rec := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]string{"registration_number": "  PT-123456  "})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// Trimmed like name/address — the field is copied off a paper registration
	// and pasted stray whitespace must not become part of the identifier.
	if org.RegistrationNumber != "PT-123456" {
		t.Errorf("registration_number = %q, want PT-123456 (trimmed)", org.RegistrationNumber)
	}

	// A later GET sees the stored value (it is not a write-only echo).
	got := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, adminBearer, nil)
	if got.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200, body = %s", got.Code, got.Body.String())
	}
	var reread api.OrganizationResponse
	if err := json.Unmarshal(got.Body.Bytes(), &reread); err != nil {
		t.Fatalf("decode GET: %v", err)
	}
	if reread.RegistrationNumber != "PT-123456" {
		t.Errorf("re-read registration_number = %q, want PT-123456", reread.RegistrationNumber)
	}

	entries := f.auditLogFor(t, "organization", orgID)
	if len(entries) == 0 {
		t.Fatal("no audit log entry for the registration_number update (FR-HIS-1)")
	}
}

// TestUpdateOrganization_RegistrationNumberNullClears mirrors
// TestUpdateOrganization_AddressNullClears: the field is nullable in the
// contract, an explicit JSON null clears it, and omitting the key leaves it
// alone. Clearing matters — a beekeeper who mistypes the number must be able
// to remove it, not just overwrite it.
func TestUpdateOrganization_RegistrationNumberNullClears(t *testing.T) {
	adminSub := "a9222222-2222-4222-8222-222222222222"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000d2"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000292"
	etag := newAdminOrg(t, f, adminBearer, orgID, "Org", "Addr")

	set := f.doWithHeaders(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"If-Match": etag},
		map[string]string{"registration_number": "PT-999"})
	if set.Code != http.StatusOK {
		t.Fatalf("set status = %d, want 200, body = %s", set.Code, set.Body.String())
	}

	// A name-only PATCH must not disturb it (absent key != null).
	keep := f.do(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"name": "Renamed"})
	if keep.Code != http.StatusOK {
		t.Fatalf("name-only PATCH status = %d, want 200, body = %s", keep.Code, keep.Body.String())
	}
	var kept api.OrganizationResponse
	if err := json.Unmarshal(keep.Body.Bytes(), &kept); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if kept.RegistrationNumber != "PT-999" {
		t.Errorf("registration_number = %q after a name-only PATCH, want PT-999 (untouched)", kept.RegistrationNumber)
	}

	cleared := f.do(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]any{"registration_number": nil})
	if cleared.Code != http.StatusOK {
		t.Fatalf("clear status = %d, want 200, body = %s", cleared.Code, cleared.Body.String())
	}
	var org api.OrganizationResponse
	if err := json.Unmarshal(cleared.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.RegistrationNumber != "" {
		t.Errorf("registration_number = %q, want empty (explicit null clears it)", org.RegistrationNumber)
	}
}

// TestUpdateOrganization_RegistrationNumberTooLong_Returns422 covers
// NFR-SEC-1 input validation: the field is bounded server-side like every
// other free-text org field, and an over-long value changes nothing.
func TestUpdateOrganization_RegistrationNumberTooLong_Returns422(t *testing.T) {
	adminSub := "a9333333-3333-4333-8333-333333333333"
	f := newOrgFixture(t, map[string]string{adminSub: "a0000000-0000-7000-8000-0000000000d3"})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000293"
	newAdminOrg(t, f, adminBearer, orgID, "Org", "Addr")

	rec := f.do(t, http.MethodPatch, "/v1/organizations/"+orgID, adminBearer,
		map[string]string{"registration_number": strings.Repeat("9", 51)})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("PATCH status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}

	got := f.do(t, http.MethodGet, "/v1/organizations/"+orgID, adminBearer, nil)
	var org api.OrganizationResponse
	if err := json.Unmarshal(got.Body.Bytes(), &org); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if org.RegistrationNumber != "" {
		t.Errorf("registration_number = %q after a rejected PATCH, want empty (no partial write)", org.RegistrationNumber)
	}
}
