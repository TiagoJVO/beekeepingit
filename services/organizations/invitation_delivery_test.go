package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/shared/mail"
)

// #641 (FR-ONB-3, FR-TEN-2, D-3) — the invitation email actually leaves the
// service, its state is reported honestly, and a failure is retryable.
//
// These run against the same containerized Postgres as the rest of this
// package (main_test.go), so they are CI-only on a machine without Docker. The
// message's own content and escaping are covered by pure unit tests in
// api/invitation_email_test.go, which run anywhere.

// fakeMailer records every message instead of sending it, and can be told to
// fail — the seam api.WithMailer takes (mail.Sender), so no SMTP server is
// involved in these tests at all.
type fakeMailer struct {
	mu   sync.Mutex
	sent []mail.Message
	// err, when non-nil, is returned by every Send. Set through failWith.
	err error
}

func (f *fakeMailer) Send(_ context.Context, msg mail.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	f.sent = append(f.sent, msg)
	return nil
}

func (f *fakeMailer) failWith(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *fakeMailer) messages() []mail.Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]mail.Message, len(f.sent))
	copy(out, f.sent)
	return out
}

const testAppBaseURL = "https://app.beekeepingit.test"

// AC 1 + AC 2: creating an invitation SENDS an email to the invited address,
// and that email identifies the organization and the inviter and links to the
// sign-up flow.
func TestCreateInvitation_SendsEmailNamingOrganizationInviterAndSignUpLink(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	inviteeEmail := "invitee@example.com"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID, Name: "Ana Admin", Locale: "en-GB"}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000641"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": inviteeEmail,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, body = %s", rec.Code, rec.Body.String())
	}

	sent := mailer.messages()
	if len(sent) != 1 {
		t.Fatalf("sent %d emails, want exactly 1", len(sent))
	}
	msg := sent[0]
	if msg.To != inviteeEmail {
		t.Errorf("To = %q, want the invited address %q", msg.To, inviteeEmail)
	}
	if !strings.Contains(msg.Subject, "Dev Apiary Co.") {
		t.Errorf("subject does not name the organization: %q", msg.Subject)
	}
	if !strings.Contains(msg.TextBody, "Ana Admin") {
		t.Errorf("body does not name the inviter: %q", msg.TextBody)
	}
	if !strings.Contains(msg.TextBody, testAppBaseURL+"/login") {
		t.Errorf("body does not link to the sign-up flow: %q", msg.TextBody)
	}

	// AC 4: the response says the email actually went out.
	var created api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if created.DeliveryStatus != "sent" {
		t.Errorf("delivery_status = %q, want sent", created.DeliveryStatus)
	}
	if created.DeliveryError != "" {
		t.Errorf("delivery_error = %q, want empty on a successful send", created.DeliveryError)
	}
	if created.LastDeliveryAt == nil {
		t.Error("last_delivery_at is null after a send attempt")
	}
	// The lifecycle status is untouched by delivery — it is still the
	// invitee's to move.
	if created.Status != "pending" {
		t.Errorf("status = %q, want pending", created.Status)
	}
}

// AC 3: the recipient's own language wins when identity knows the address.
func TestCreateInvitation_UsesTheRecipientsLanguageWhenKnown(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	inviteeSub := "b2222222-2222-4222-8222-222222222222"
	inviteeEmail := "convidado@example.com"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{
			// The ADMIN is English, so the organization's own locale is
			// en-GB — the recipient's pt-PT profile must still win.
			adminSub:   {UserID: adminUserID, Name: "Ana", Locale: "en-GB"},
			inviteeSub: {UserID: "a0000000-0000-7000-8000-0000000000b2", Email: inviteeEmail, Locale: "pt-PT"},
		},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000642"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": inviteeEmail,
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, body = %s", rec.Code, rec.Body.String())
	}

	sent := mailer.messages()
	if len(sent) != 1 {
		t.Fatalf("sent %d emails, want 1", len(sent))
	}
	if !strings.Contains(sent[0].TextBody, "iniciar sessão") {
		t.Errorf("email is not in the recipient's language (pt-PT): %q", sent[0].TextBody)
	}
}

// AC 3, the other half: an address identity has never seen falls back to the
// ORGANIZATION's language, which is seeded from its creating admin (D-3).
func TestCreateInvitation_FallsBackToTheOrganizationsLanguage(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID, Name: "Ana", Locale: "pt-PT"}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000643"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Apiário São João",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	// nobody@example.com has no identity profile at all.
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "nobody@example.com",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, body = %s", rec.Code, rec.Body.String())
	}

	sent := mailer.messages()
	if len(sent) != 1 {
		t.Fatalf("sent %d emails, want 1", len(sent))
	}
	if !strings.Contains(sent[0].TextBody, "iniciar sessão") {
		t.Errorf("email did not fall back to the organization's language (pt-PT): %q", sent[0].TextBody)
	}
}

// AC 4 + AC 5: a failed send is REPORTED as failed (not swallowed, and not
// turned into a 5xx that would hide a real invitation), and it is retryable.
func TestCreateInvitation_FailedSendIsVisibleAndRetryable(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	mailer := &fakeMailer{}
	mailer.failWith(&mail.StepError{Step: "rcpt to", Code: 550})

	// A clock the test controls, so the resend cooldown can be stepped over
	// without sleeping.
	now := time.Now().UTC()
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID, Name: "Ana", Locale: "en-GB"}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
		api.WithClock(func() time.Time { return now }),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000644"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "invitee@example.com",
	})
	// The invitation EXISTS even though its email did not go out — reporting
	// a 5xx here would leave a real row behind an error message.
	if rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, want 201 even on a failed send, body = %s", rec.Code, rec.Body.String())
	}
	var created api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if created.DeliveryStatus != "failed" {
		t.Fatalf("delivery_status = %q, want failed", created.DeliveryStatus)
	}
	// A 5xx from the relay is permanent for this message, so the admin is told
	// the address/message was rejected rather than sent chasing a broken relay.
	if created.DeliveryError != "rejected" {
		t.Errorf("delivery_error = %q, want rejected", created.DeliveryError)
	}

	// The admin sees the same truth in the list, not only in the create
	// response (the list is the screen #641 is about).
	recList := f.do(t, http.MethodGet, "/v1/organizations/"+orgID+"/invitations", adminBearer, nil)
	var list struct {
		Data []api.InvitationResponse `json:"data"`
	}
	if err := json.Unmarshal(recList.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list.Data) != 1 || list.Data[0].DeliveryStatus != "failed" {
		t.Fatalf("list = %+v, want one invitation with delivery_status failed", list.Data)
	}

	// Retry: too soon — the per-invitation cooldown answers 429 with advice.
	resendPath := "/v1/organizations/" + orgID + "/invitations/" + created.ID + "/resend"
	if rec := f.do(t, http.MethodPost, resendPath, adminBearer, nil); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("immediate resend status = %d, want 429, body = %s", rec.Code, rec.Body.String())
	} else if rec.Header().Get("Retry-After") == "" {
		t.Error("429 carries no Retry-After header")
	}

	// Retry after the cooldown, with the relay now working: it succeeds, and
	// the invitation's delivery state flips to sent.
	now = now.Add(2 * time.Minute)
	mailer.failWith(nil)
	recResend := f.do(t, http.MethodPost, resendPath, adminBearer, nil)
	if recResend.Code != http.StatusOK {
		t.Fatalf("resend status = %d, want 200, body = %s", recResend.Code, recResend.Body.String())
	}
	var resent api.InvitationResponse
	if err := json.Unmarshal(recResend.Body.Bytes(), &resent); err != nil {
		t.Fatalf("decode resend: %v", err)
	}
	if resent.DeliveryStatus != "sent" || resent.DeliveryError != "" {
		t.Errorf("after a successful retry: delivery_status = %q, delivery_error = %q, want sent/empty",
			resent.DeliveryStatus, resent.DeliveryError)
	}
	if len(mailer.messages()) != 1 {
		t.Errorf("relay received %d messages, want 1 (only the successful retry)", len(mailer.messages()))
	}
}

// An environment with no relay provisioned yet (staging/prod until #417) must
// still create invitations, and must say plainly that nothing was sent —
// never claim delivery.
func TestCreateInvitation_NoRelayConfigured_RecordsNotConfigured(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	// No api.WithMailer at all — exactly how PublicRouter is built when
	// main.go finds no usable SMTP configuration.
	f := newOrgFixtureWithEmails(t, map[string]stubUser{adminSub: {UserID: adminUserID}})
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000645"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "invitee@example.com",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var created api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if created.DeliveryStatus != "failed" || created.DeliveryError != "not_configured" {
		t.Fatalf("delivery = %q/%q, want failed/not_configured",
			created.DeliveryStatus, created.DeliveryError)
	}
}

// SECURITY (#641 review): this endpoint mails a caller-chosen address, so it
// is rate limited per organization. Without the limit an admin session is an
// open relay.
func TestCreateInvitation_RateLimitedPerOrganization(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000646"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}

	// The budget is 20 per hour (api/invitation_delivery.go). Drive one past
	// it and assert the 21st is refused rather than mailed.
	const budget = 20
	for i := range budget {
		rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
			"email": fmt.Sprintf("invitee%d@example.com", i),
		})
		if rec.Code != http.StatusCreated {
			t.Fatalf("invitation %d status = %d, body = %s", i, rec.Code, rec.Body.String())
		}
	}
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "one-too-many@example.com",
	})
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("over-budget invitation status = %d, want 429, body = %s", rec.Code, rec.Body.String())
	}
	if got := len(mailer.messages()); got != budget {
		t.Errorf("relay received %d messages, want %d — the refused invitation must not have been mailed", got, budget)
	}
	// The refusal must not narrate the tenant's own recent activity.
	if body := rec.Body.String(); strings.Contains(body, "20 invitations in the last") {
		t.Errorf("429 body leaks usage detail: %s", body)
	}
}

// A resolved invitation must never be re-advertised to the address it was
// withdrawn from.
func TestResendInvitation_NotPending_Returns409(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000647"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "invitee@example.com",
	})
	var created api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if rec := f.do(t, http.MethodDelete, "/v1/organizations/"+orgID+"/invitations/"+created.ID, adminBearer, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, body = %s", rec.Code, rec.Body.String())
	}

	before := len(mailer.messages())
	rec = f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations/"+created.ID+"/resend", adminBearer, nil)
	if rec.Code != http.StatusConflict {
		t.Fatalf("resend of a revoked invitation status = %d, want 409, body = %s", rec.Code, rec.Body.String())
	}
	if len(mailer.messages()) != before {
		t.Error("a revoked invitation was re-mailed")
	}
}

// Tenancy (ADR-0002): the resend route is admin-only within the caller's own
// org, like every other invitation write.
func TestResendInvitation_NonAdmin_Returns403(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	memberSub := "c3333333-3333-4333-8333-333333333333"
	memberUserID := "a0000000-0000-7000-8000-0000000000c3"
	memberEmail := "member@example.com"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{
			adminSub:  {UserID: adminUserID},
			memberSub: {UserID: memberUserID, Email: memberEmail},
		},
		map[string]tokenClaim{memberSub: {Email: memberEmail, EmailVerified: true}},
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)
	memberBearer := f.token(t, memberSub)

	orgID := "b0000000-0000-7000-8000-000000000648"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	// Invite the member and let them join, so they are an ACTIVE non-admin
	// member of this exact org (a 403, not the 404 an outsider would get).
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": memberEmail,
	})
	var memberInvitation api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &memberInvitation); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", memberBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("member accept-on-login status = %d, body = %s", rec.Code, rec.Body.String())
	}

	rec = f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "someone-else@example.com",
	})
	var other api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &other); err != nil {
		t.Fatalf("decode: %v", err)
	}

	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations/"+other.ID+"/resend", memberBearer, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin resend status = %d, want 403, body = %s", rec.Code, rec.Body.String())
	}
}

// A failed email must NOT stop the invitation from being claimable: the admin
// can still tell the invitee by another channel, and accept-on-login matches
// on the verified address, never on delivery state.
func TestFailedDelivery_DoesNotBlockAcceptOnLogin(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	inviteeSub := "b2222222-2222-4222-8222-222222222222"
	inviteeEmail := "invitee@example.com"

	mailer := &fakeMailer{}
	mailer.failWith(&mail.StepError{Step: "connect", Code: 421})
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{
			adminSub:   {UserID: adminUserID},
			inviteeSub: {UserID: "a0000000-0000-7000-8000-0000000000b2", Email: inviteeEmail},
		},
		map[string]tokenClaim{inviteeSub: {Email: inviteeEmail, EmailVerified: true}},
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)
	inviteeBearer := f.token(t, inviteeSub)

	orgID := "b0000000-0000-7000-8000-000000000649"
	if rec := f.do(t, http.MethodPost, "/v1/organizations", adminBearer, map[string]string{
		"id": orgID, "name": "Dev Apiary Co.",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": inviteeEmail,
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, body = %s", rec.Code, rec.Body.String())
	}

	if rec := f.do(t, http.MethodGet, "/v1/organizations/me", inviteeBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("accept-on-login after a failed send status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
}
