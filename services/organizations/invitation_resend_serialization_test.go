package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/organizations/api"
	"github.com/TiagoJVO/beekeepingit/services/shared/mail"
)

// #854 (FR-ONB-3, FR-TEN-2, NFR-SEC-1, D-3) — the resend path's three
// remaining read-then-act windows, follow-ups from #641's security review:
//
//  1. the per-invitation cooldown was read on the pool and acted on later, so
//     concurrent resends of ONE invitation all saw the same pre-attempt state;
//  2. resend was not counted against the organization's hourly budget at all;
//  3. delivery bookkeeping failed OPEN — the attempt was only recorded AFTER
//     the SMTP conversation, so a failure to persist it left the cooldown and
//     the attempt counter un-advanced although mail had gone out.
//
// Like the rest of this package these run against a containerized Postgres
// (main_test.go), so they are CI-only on a machine without Docker. Nothing
// here can be expressed against a mock: what is under test is exactly what the
// database does when two transactions collide.

// inspectingMailer runs onSend at the moment the SMTP conversation would
// start, then delegates to a normal fakeMailer. It is how a test observes the
// state of the invitation row DURING a send — the ordering that decides
// whether the bookkeeping fails open or closed.
type inspectingMailer struct {
	inner  *fakeMailer
	onSend func(msg mail.Message)
}

func (m *inspectingMailer) Send(ctx context.Context, msg mail.Message) error {
	if m.onSend != nil {
		m.onSend(msg)
	}
	return m.inner.Send(ctx, msg)
}

// barrierMailer holds every send inside the SMTP conversation until `want` of
// them have arrived (or a deadline passes), and counts how many ever got
// there.
//
// This is what makes the concurrency test below DETERMINISTIC rather than a
// coin toss. A plain pair of goroutines does not reliably expose a read-then-
// act race: the whole request path here is in-process against a local
// container, so one racer routinely finishes before the other starts its own
// read, and the test then passes against code that has the bug. Blocking
// inside the send widens the window to the full duration of the barrier, which
// is exactly the window the old code left open — it read the cooldown, then
// sent, then recorded the attempt.
//
// So: two entrants means the limits let two sends through, every time. One
// entrant (releasing on the deadline instead) means only one ever got past
// them.
type barrierMailer struct {
	inner *fakeMailer

	mu      sync.Mutex
	want    int
	entered int
	release chan struct{}
	timeout time.Duration
}

// arm makes the next `want` sends block until all of them have arrived. Sends
// before arm (the create-time ones a test's fixture makes) pass straight
// through and are not counted.
func (m *barrierMailer) arm(want int, timeout time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.want = want
	m.entered = 0
	m.release = make(chan struct{})
	m.timeout = timeout
}

func (m *barrierMailer) Send(ctx context.Context, msg mail.Message) error {
	m.mu.Lock()
	release, timeout := m.release, m.timeout
	if release != nil {
		m.entered++
		if m.entered >= m.want {
			close(m.release)
			m.release = nil
		}
	}
	m.mu.Unlock()

	if release != nil {
		select {
		case <-release:
		case <-time.After(timeout):
		}
	}
	return m.inner.Send(ctx, msg)
}

// concurrentSenders is how many sends reached the barrier since arm.
func (m *barrierMailer) concurrentSenders() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.entered
}

// deliveryState is the pair of columns that together ARE the rate limit:
// how many attempts this invitation has spent, and when the last one started.
type deliveryState struct {
	Attempts       int
	LastDeliveryAt *time.Time
}

func deliveryStateOf(t *testing.T, f *orgFixture, invitationID string) deliveryState {
	t.Helper()
	var got deliveryState
	if err := f.pool.QueryRow(context.Background(),
		`SELECT delivery_attempts, last_delivery_at FROM organizations.invitations WHERE id = $1`,
		invitationID).Scan(&got.Attempts, &got.LastDeliveryAt); err != nil {
		t.Fatalf("read delivery state: %v", err)
	}
	return got
}

// backdateDelivery pushes an invitation's last attempt into the past so the
// cooldown is satisfied without sleeping and without a fake clock the test's
// own goroutines would race on.
func backdateDelivery(t *testing.T, f *orgFixture, invitationID string, age time.Duration) {
	t.Helper()
	if _, err := f.pool.Exec(context.Background(),
		`UPDATE organizations.invitations SET last_delivery_at = now() - $2::interval WHERE id = $1`,
		invitationID, fmt.Sprintf("%d seconds", int(age.Seconds()))); err != nil {
		t.Fatalf("backdate last_delivery_at: %v", err)
	}
}

func createOrgAndInvitation(t *testing.T, f *orgFixture, bearer, orgID, orgName, email string) api.InvitationResponse {
	t.Helper()
	if rec := f.do(t, http.MethodPost, "/v1/organizations", bearer, map[string]string{
		"id": orgID, "name": orgName,
	}); rec.Code != http.StatusCreated {
		t.Fatalf("create org status = %d, body = %s", rec.Code, rec.Body.String())
	}
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", bearer, map[string]string{
		"email": email,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create invitation status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var created api.InvitationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode invitation: %v", err)
	}
	return created
}

// #854 finding 1 — the cooldown is only a cooldown if it is serialized.
//
// Two resends of ONE invitation are fired from goroutines released by a shared
// start channel, against a real Postgres (not a mock), and the mailer holds
// whoever gets into the SMTP conversation there until BOTH have arrived or a
// deadline passes (see barrierMailer). Read-then-act on the pool lets both
// observe the same pre-attempt last_delivery_at, both pass the cooldown, and
// both mail the address — the mailbomb the doc comment on
// resendInvitationHandler claims cannot happen. With the attempt slot claimed
// by a single conditional UPDATE under the per-org lock (the same
// LockOrganizationForUpdate the last-admin guard and the create budget use),
// exactly one of the two claims the slot, the other never reaches the mailer,
// and the barrier is released by its deadline instead.
//
// The loser's status may be 429 (it re-read the row after the winner
// committed, so the cooldown now bites) or 409 (its claim matched zero rows);
// both are correct refusals. What this test pins is the invariant: one send,
// one attempt spent.
func TestResendInvitation_ConcurrentResendsClaimOneAttemptSlot(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	inner := &fakeMailer{}
	mailer := &barrierMailer{inner: inner}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000854"
	created := createOrgAndInvitation(t, f, adminBearer, orgID, "Race Apiary Co.", "invitee@example.com")

	// The create already spent attempt 1. Age it past the cooldown so both
	// racers are genuinely eligible when they start.
	backdateDelivery(t, f, created.ID, 5*time.Minute)

	resendPath := "/v1/organizations/" + orgID + "/invitations/" + created.ID + "/resend"
	resend := func() int {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, resendPath, nil)
		req.Header.Set("Authorization", adminBearer)
		f.srv.Router().ServeHTTP(rec, req)
		return rec.Code
	}

	// Hold every send that arrives until both racers are inside it. Under the
	// fix only one ever arrives, so the barrier falls back to its deadline —
	// which is why the deadline is short.
	const racers = 2
	mailer.arm(racers, 3*time.Second)

	start := make(chan struct{})
	var wg sync.WaitGroup
	codes := make([]int, racers)
	for i := range racers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			codes[i] = resend()
		}(i)
	}
	close(start)
	wg.Wait()

	var sent, refused int
	for _, code := range codes {
		switch code {
		case http.StatusOK:
			sent++
		case http.StatusTooManyRequests, http.StatusConflict:
			refused++
		default:
			t.Errorf("unexpected status %d among concurrent resends %v", code, codes)
		}
	}
	if sent != 1 || refused != 1 {
		t.Fatalf("concurrent resends = %v, want exactly one 200 and one refusal (429 or 409) — the cooldown must serialize", codes)
	}

	// The decisive assertion: only ONE request ever got as far as the SMTP
	// conversation. Two means both passed limits that are supposed to be
	// spent by the same statement that checks them.
	if got := mailer.concurrentSenders(); got != 1 {
		t.Errorf("%d concurrent resends reached the mailer, want 1 — the cooldown and the attempt cap must be claimed, not merely read", got)
	}
	// One create send plus exactly one resend. Two would mean the address was
	// mailed twice inside the cooldown window.
	if got := len(inner.messages()); got != 2 {
		t.Errorf("relay received %d messages, want 2 (the create send and exactly one resend)", got)
	}
	if got := deliveryStateOf(t, f, created.ID).Attempts; got != 2 {
		t.Errorf("delivery_attempts = %d, want 2 — two concurrent resends must spend exactly one slot between them", got)
	}
}

// #854 finding 3 — the attempt slot is claimed BEFORE the SMTP conversation,
// so the bookkeeping fails closed.
//
// The old order was send-then-record: if recording the outcome failed, the mail
// had gone but delivery_attempts and last_delivery_at had not moved, so the
// next call was uncooled and the lifetime cap had not been charged. Claiming
// first inverts that — the worst case becomes a spent attempt whose outcome is
// unknown, which is the safe direction for a rate limit.
//
// Observed from inside the mailer: at the instant the send starts, the row must
// already show the attempt.
func TestInvitationDelivery_ClaimsTheAttemptSlotBeforeSending(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"
	inviteeEmail := "invitee@example.com"

	var (
		mu       sync.Mutex
		observed []deliveryState
	)
	inner := &fakeMailer{}
	mailer := &inspectingMailer{inner: inner}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	mailer.onSend = func(mail.Message) {
		var got deliveryState
		if err := f.pool.QueryRow(context.Background(),
			`SELECT delivery_attempts, last_delivery_at FROM organizations.invitations WHERE lower(email) = $1`,
			inviteeEmail).Scan(&got.Attempts, &got.LastDeliveryAt); err != nil {
			t.Errorf("read delivery state during send: %v", err)
			return
		}
		mu.Lock()
		observed = append(observed, got)
		mu.Unlock()
	}
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000855"
	created := createOrgAndInvitation(t, f, adminBearer, orgID, "Bookkeeping Apiary Co.", inviteeEmail)

	backdateDelivery(t, f, created.ID, 5*time.Minute)
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations/"+created.ID+"/resend", adminBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("resend status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	mu.Lock()
	defer mu.Unlock()
	if len(observed) != 2 {
		t.Fatalf("observed %d sends, want 2 (the create send and the resend)", len(observed))
	}
	// The create's own send: the row it is sending for must already have been
	// charged for this attempt.
	if observed[0].Attempts != 1 {
		t.Errorf("during the create send delivery_attempts = %d, want 1 — the attempt must be claimed before the mail leaves", observed[0].Attempts)
	}
	if observed[0].LastDeliveryAt == nil {
		t.Error("during the create send last_delivery_at is NULL — a lost outcome write would leave the first resend uncooled")
	}
	// The resend's send: attempt 2, and the cooldown clock already restarted
	// (the test backdated it by five minutes, so a stamp inside the last
	// minute can only be this attempt's own claim).
	if observed[1].Attempts != 2 {
		t.Errorf("during the resend delivery_attempts = %d, want 2 — the attempt must be claimed before the mail leaves", observed[1].Attempts)
	}
	if observed[1].LastDeliveryAt == nil || time.Since(*observed[1].LastDeliveryAt) > time.Minute {
		t.Errorf("during the resend last_delivery_at = %v, want a stamp from this attempt's own claim", observed[1].LastDeliveryAt)
	}
}

// #854 finding 2 — a resend spends the organization's hourly budget.
//
// The budget exists because this service mails caller-chosen addresses (#641
// security review, NFR-SEC-1). Resend can target any still-pending invitation
// of any age, so counting only CREATED invitations left an admin session able
// to drive unbounded mail at addresses it had invited earlier — the hourly
// ceiling simply did not apply to it.
//
// The window is deliberately shared with creation rather than given its own
// counter: the thing being bounded is outbound mail per organization per hour,
// not the endpoint that triggered it.
func TestResendInvitation_SpendsTheOrganizationsHourlyBudget(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000856"
	created := createOrgAndInvitation(t, f, adminBearer, orgID, "Budget Apiary Co.", "old-invitee@example.com")

	// Age the whole organization out of the budget window, so what follows
	// starts from an empty hour and the arithmetic below is exact.
	if _, err := f.pool.Exec(context.Background(),
		`UPDATE organizations.invitations
		 SET created_at = now() - interval '2 hours', last_delivery_at = now() - interval '2 hours'
		 WHERE organization_id = $1`, orgID); err != nil {
		t.Fatalf("age the organization's invitations: %v", err)
	}

	// One resend of that old invitation. It mails an address, so it spends one
	// of the twenty slots in this hour.
	if rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations/"+created.ID+"/resend", adminBearer, nil); rec.Code != http.StatusOK {
		t.Fatalf("resend status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}

	// Nineteen more sends fit in the same hour; the twentieth does not,
	// because the resend already took a slot.
	const budget = 20
	for i := range budget - 1 {
		rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
			"email": fmt.Sprintf("invitee%d@example.com", i),
		})
		if rec.Code != http.StatusCreated {
			t.Fatalf("invitation %d status = %d, want 201, body = %s", i, rec.Code, rec.Body.String())
		}
	}
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
		"email": "one-too-many@example.com",
	})
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("invitation after a resend + %d creates status = %d, want 429 — the resend must have spent a budget slot, body = %s",
			budget-1, rec.Code, rec.Body.String())
	}
	// The first create, the resend, and the nineteen creates — and nothing for
	// the refused one.
	const wantMessages = 1 + 1 + (budget - 1)
	if got := len(mailer.messages()); got != wantMessages {
		t.Errorf("relay received %d messages, want %d — the refused invitation must not have been mailed", got, wantMessages)
	}
}

// #854 finding 2, the other direction: an organization that has exhausted its
// hourly budget cannot use resend as a way around it.
func TestResendInvitation_RefusedWhenTheHourlyBudgetIsExhausted(t *testing.T) {
	adminSub := "a1111111-1111-4111-8111-111111111111"
	adminUserID := "a0000000-0000-7000-8000-0000000000a1"

	mailer := &fakeMailer{}
	f := newOrgFixtureWithMailer(t,
		map[string]stubUser{adminSub: {UserID: adminUserID}},
		nil,
		api.WithMailer(mailer, testAppBaseURL),
	)
	adminBearer := f.token(t, adminSub)

	orgID := "b0000000-0000-7000-8000-000000000857"
	created := createOrgAndInvitation(t, f, adminBearer, orgID, "Exhausted Apiary Co.", "first@example.com")

	const budget = 20
	for i := range budget - 1 {
		rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations", adminBearer, map[string]string{
			"email": fmt.Sprintf("invitee%d@example.com", i),
		})
		if rec.Code != http.StatusCreated {
			t.Fatalf("invitation %d status = %d, want 201, body = %s", i, rec.Code, rec.Body.String())
		}
	}

	// The hour is now full. The cooldown on the first invitation is satisfied,
	// so only the budget can refuse this.
	backdateDelivery(t, f, created.ID, 5*time.Minute)
	before := len(mailer.messages())
	rec := f.do(t, http.MethodPost, "/v1/organizations/"+orgID+"/invitations/"+created.ID+"/resend", adminBearer, nil)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("resend with the budget exhausted status = %d, want 429, body = %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("429 carries no Retry-After header")
	}
	if got := len(mailer.messages()); got != before {
		t.Errorf("relay received %d messages after a refused resend, want %d — nothing may be mailed past the budget", got, before)
	}
	if got := deliveryStateOf(t, f, created.ID).Attempts; got != 1 {
		t.Errorf("delivery_attempts = %d after a refused resend, want 1 — a refusal must not spend an attempt", got)
	}
}
