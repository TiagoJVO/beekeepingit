package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

type stubApiaries struct {
	server         *httptest.Server
	validateStatus int
	applyStatus    int
	applyBody      string
	validateHits   int32
	applyHits      int32
	sawBearer      int32 // 1 if a bearer was forwarded on any call
}

func newStubApiaries(t *testing.T) *stubApiaries {
	s := &stubApiaries{validateStatus: http.StatusOK, applyStatus: http.StatusOK, applyBody: `{"results":[]}`}
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/sync/validate", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&s.validateHits, 1)
		if r.Header.Get("Authorization") != "" {
			atomic.StoreInt32(&s.sawBearer, 1)
		}
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/problem+json")
		w.WriteHeader(s.validateStatus)
		if s.validateStatus == http.StatusUnprocessableEntity {
			_, _ = w.Write([]byte(`{"title":"Validation failed","status":422,"code":"validation.failed"}`))
		}
	})
	mux.HandleFunc("/internal/sync/apply", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&s.applyHits, 1)
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(s.applyStatus)
		_, _ = w.Write([]byte(s.applyBody))
	})
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

// captureDefaultLogger redirects slog's package-level default logger to a
// buffer for the duration of the test, restoring the previous default on
// cleanup. The coordinator logs upstream transport failures via
// slog.ErrorContext, which logs through the default logger.
func captureDefaultLogger(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return &buf
}

// TestCoordinator_Handle is a table-driven test over the two-phase
// validate-then-apply contract (sync.md §6.2): a validate rejection must
// short-circuit before apply ever runs, and any non-2xx from either phase
// (transient failure or the upstream being unreachable) must relay as 502 so
// PowerSync retries the still-queued batch.
func TestCoordinator_Handle(t *testing.T) {
	cases := []struct {
		name              string
		validateStatus    int
		applyStatus       int
		useUnreachableURL bool
		wantStatus        int
		wantValidateHits  int32
		wantApplyHits     int32
	}{
		{
			name: "validate then apply succeeds", validateStatus: http.StatusOK, applyStatus: http.StatusOK,
			wantStatus: http.StatusOK, wantValidateHits: 1, wantApplyHits: 1,
		},
		{
			name: "validate reject relays 422 without applying", validateStatus: http.StatusUnprocessableEntity,
			wantStatus: http.StatusUnprocessableEntity, wantValidateHits: 1, wantApplyHits: 0,
		},
		{
			name: "apply transient failure maps to 502", validateStatus: http.StatusOK, applyStatus: http.StatusInternalServerError,
			wantStatus: http.StatusBadGateway, wantValidateHits: 1, wantApplyHits: 1,
		},
		{
			name: "upstream down maps to 502", useUnreachableURL: true,
			wantStatus: http.StatusBadGateway,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var c *Coordinator
			var stub *stubApiaries
			if tc.useUnreachableURL {
				var err error
				c, err = NewCoordinator("http://127.0.0.1:1", "http://127.0.0.1:1")
				if err != nil {
					t.Fatalf("NewCoordinator: %v", err)
				}
			} else {
				stub = newStubApiaries(t)
				stub.validateStatus = tc.validateStatus
				stub.applyStatus = tc.applyStatus
				var err error
				c, err = NewCoordinator(stub.server.URL, stub.server.URL)
				if err != nil {
					t.Fatalf("NewCoordinator: %v", err)
				}
			}

			resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
			if resp.status != tc.wantStatus {
				t.Fatalf("status = %d, want %d, body = %s", resp.status, tc.wantStatus, resp.body)
			}
			if stub != nil {
				if got := atomic.LoadInt32(&stub.validateHits); got != tc.wantValidateHits {
					t.Errorf("validateHits = %d, want %d", got, tc.wantValidateHits)
				}
				if got := atomic.LoadInt32(&stub.applyHits); got != tc.wantApplyHits {
					t.Errorf("applyHits = %d, want %d", got, tc.wantApplyHits)
				}
			}
		})
	}
}

// TestCoordinator_Success_ForwardsBearerAndRelaysApplyBody covers what the
// table above deliberately leaves out: the exact bearer/body plumbing on the
// happy path.
func TestCoordinator_Success_ForwardsBearerAndRelaysApplyBody(t *testing.T) {
	stub := newStubApiaries(t)
	stub.applyBody = `{"results":[{"id":"x","op":"put","result":"applied"}]}`
	c, err := NewCoordinator(stub.server.URL, stub.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if resp.status != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.status)
	}
	if string(resp.body) != stub.applyBody {
		t.Errorf("body = %s, want %s", resp.body, stub.applyBody)
	}
	if atomic.LoadInt32(&stub.sawBearer) != 1 {
		t.Error("bearer was not forwarded upstream")
	}
}

// TestCoordinator_ValidateTransportFailure_LogsAndReturns502 is HIGH #2: a
// DNS/connection/TLS/timeout failure calling the owning service's validate
// endpoint must be logged (there was previously zero diagnostic trail) while
// still mapping to a 502 for the caller.
func TestCoordinator_ValidateTransportFailure_LogsAndReturns502(t *testing.T) {
	buf := captureDefaultLogger(t)
	c, err := NewCoordinator("http://127.0.0.1:1", "http://127.0.0.1:1")
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if resp.status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.status)
	}
	if !strings.Contains(buf.String(), "sync validate call failed") {
		t.Errorf("expected the validate transport failure to be logged, got: %s", buf.String())
	}
	if !strings.Contains(buf.String(), `"level":"ERROR"`) {
		t.Errorf("expected an ERROR-level log record, got: %s", buf.String())
	}
}

// TestCoordinator_ApplyTransportFailure_LogsAndReturns502 is the apply-phase
// counterpart: the connection is hijacked and closed mid-response (rather
// than answered with an HTTP status) to simulate a genuine transport failure
// distinct from a well-formed 5xx status.
func TestCoordinator_ApplyTransportFailure_LogsAndReturns502(t *testing.T) {
	buf := captureDefaultLogger(t)

	mux := http.NewServeMux()
	mux.HandleFunc("/internal/sync/validate", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/internal/sync/apply", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		if hj, ok := w.(http.Hijacker); ok {
			if conn, _, err := hj.Hijack(); err == nil {
				_ = conn.Close()
			}
		}
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	c, err := NewCoordinator(server.URL, server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if resp.status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.status)
	}
	if !strings.Contains(buf.String(), "sync apply call failed") {
		t.Errorf("expected the apply transport failure to be logged, got: %s", buf.String())
	}
}

// TestCoordinator_UpstreamResponseBody_IsSizeCapped is MEDIUM #1: reading the
// upstream response had no size cap, asymmetric with the request-side cap
// applied to the inbound client batch.
func TestCoordinator_UpstreamResponseBody_IsSizeCapped(t *testing.T) {
	oversized := bytes.Repeat([]byte("x"), maxBatchBytes+1024)
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/sync/validate", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/internal/sync/apply", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(oversized)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	c, err := NewCoordinator(server.URL, server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if len(resp.body) > maxBatchBytes {
		t.Errorf("upstream response body = %d bytes, want capped at <= %d", len(resp.body), maxBatchBytes)
	}
}

// TestBadGateway_BuildsRFC9457ProblemJSON is MEDIUM #2: badGateway must build
// its payload through the shared problem.Problem shape (marshaled), not a
// bespoke fmt.Sprintf-assembled JSON string.
func TestBadGateway_BuildsRFC9457ProblemJSON(t *testing.T) {
	resp := badGateway("sync validation is unavailable")
	if resp.status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.status)
	}
	if resp.contentType != "application/problem+json" {
		t.Errorf("contentType = %q, want application/problem+json", resp.contentType)
	}

	var p problem.Problem
	if err := json.Unmarshal(resp.body, &p); err != nil {
		t.Fatalf("decode problem+json body: %v (body = %s)", err, resp.body)
	}
	if p.Title != "Bad Gateway" {
		t.Errorf("title = %q, want Bad Gateway", p.Title)
	}
	if p.Status != http.StatusBadGateway {
		t.Errorf("status field = %d, want 502", p.Status)
	}
	if p.Detail != "sync validation is unavailable" {
		t.Errorf("detail = %q, want %q", p.Detail, "sync validation is unavailable")
	}
	if p.Code != "sync.upstream_unavailable" {
		t.Errorf("code = %q, want sync.upstream_unavailable", p.Code)
	}
}

// TestNewCoordinator_TrimsTrailingSlash is MEDIUM #3: an operator-supplied
// INTERNAL_APIARIES_URL/INTERNAL_ACTIVITIES_URL with a trailing slash must
// not produce a double-slash path when concatenated with
// "/internal/sync/...".
func TestNewCoordinator_TrimsTrailingSlash(t *testing.T) {
	c, err := NewCoordinator("http://apiaries.internal.svc/", "http://activities.internal.svc/")
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}
	if c.apiariesURL != "http://apiaries.internal.svc" {
		t.Errorf("apiariesURL = %q, want %q (trailing slash trimmed)", c.apiariesURL, "http://apiaries.internal.svc")
	}
	if c.activitiesURL != "http://activities.internal.svc" {
		t.Errorf("activitiesURL = %q, want %q (trailing slash trimmed)", c.activitiesURL, "http://activities.internal.svc")
	}
}

func TestNewCoordinator_RequiresActivitiesURL(t *testing.T) {
	if _, err := NewCoordinator("http://apiaries.internal.svc", ""); err == nil {
		t.Fatalf("NewCoordinator with an empty activitiesURL succeeded, want an error")
	}
}

// --- Multi-owning-service routing (#39, sync.md §6.1/§6.3: the first real
// second owning service) ---

// stubOwner is a minimal owning-service double recording which ops its
// validate/apply endpoints received, so a routing test can assert an op
// landed at the RIGHT service. It models the owning service's own
// idempotency (real InsertApiary/InsertActivity are keyed on the
// client-generated UUID PK): appliedOps de-duplicates by op id, so a batch
// re-sent by the coordinator's forward-retry never records the same op twice
// — the property the forward-retry design depends on.
type stubOwner struct {
	server         *httptest.Server
	mu             sync.Mutex
	validateStatus int
	applyStatus    int    // status the apply endpoint answers with (default 200)
	applyResults   string // the {"results":[...]} body to answer apply with
	validatedOps   []Op
	appliedIDs     map[string]bool // idempotent record of ops applied (by id)
	applyCalls     int             // how many times apply was invoked (incl. retries)
}

func (s *stubOwner) appliedCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.appliedIDs)
}

func (s *stubOwner) applied(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.appliedIDs[id]
}

func (s *stubOwner) applyCallCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.applyCalls
}

func (s *stubOwner) setApplyStatus(status int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.applyStatus = status
}

func newStubOwner(t *testing.T) *stubOwner {
	s := &stubOwner{
		validateStatus: http.StatusOK,
		applyStatus:    http.StatusOK,
		applyResults:   `{"results":[]}`,
		appliedIDs:     map[string]bool{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/sync/validate", func(w http.ResponseWriter, r *http.Request) {
		var batch struct {
			Ops []Op `json:"ops"`
		}
		_ = json.NewDecoder(r.Body).Decode(&batch)
		s.mu.Lock()
		s.validatedOps = append(s.validatedOps, batch.Ops...)
		vs := s.validateStatus
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/problem+json")
		w.WriteHeader(vs)
		if vs == http.StatusUnprocessableEntity {
			_, _ = w.Write([]byte(`{"title":"Validation failed","status":422,"code":"validation.failed"}`))
		}
	})
	mux.HandleFunc("/internal/sync/apply", func(w http.ResponseWriter, r *http.Request) {
		var batch struct {
			Ops []Op `json:"ops"`
		}
		_ = json.NewDecoder(r.Body).Decode(&batch)
		s.mu.Lock()
		s.applyCalls++
		as := s.applyStatus
		// A failed apply applies NOTHING (the owning service's own tx rolls
		// back), so only record ops on a 200 — modeling that a transient
		// failure leaves no partial state to duplicate on retry.
		if as == http.StatusOK {
			for _, op := range batch.Ops {
				s.appliedIDs[op.ID] = true // idempotent: re-sent id is a no-op
			}
		}
		body := s.applyResults
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(as)
		if as == http.StatusOK {
			_, _ = w.Write([]byte(body))
		}
	})
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

// Op is the minimal per-op shape these routing tests decode — a local
// stand-in for the wire shape services/apiaries/api/sync.go's Op and
// services/activities/api/sync.go's Op both use (entity_type + id are all
// that's needed to prove routing).
type Op struct {
	EntityType string `json:"entity_type"`
	ID         string `json:"id"`
}

// TestCoordinator_Handle_RoutesByEntityType is the core routing guarantee
// this PR adds: an "activity" op must reach activitiesURL, every other op
// must reach apiariesURL — NOT whichever service happens to be listed
// first, and NOT both services receiving every op.
func TestCoordinator_Handle_RoutesByEntityType(t *testing.T) {
	apiaries := newStubOwner(t)
	activities := newStubOwner(t)
	c, err := NewCoordinator(apiaries.server.URL, activities.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	body := []byte(`{"ops":[
		{"op":"put","entity_type":"apiary","id":"apiary-1","updated_at":"2026-07-16T10:00:00Z","data":{}},
		{"op":"put","entity_type":"activity","id":"activity-1","updated_at":"2026-07-16T10:00:00Z","data":{}}
	]}`)
	resp := c.handle(context.Background(), "Bearer tok", body)
	if resp.status != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", resp.status, resp.body)
	}

	if len(apiaries.validatedOps) != 1 || apiaries.validatedOps[0].ID != "apiary-1" {
		t.Fatalf("apiaries validated ops = %+v, want exactly the apiary-1 op", apiaries.validatedOps)
	}
	if len(activities.validatedOps) != 1 || activities.validatedOps[0].ID != "activity-1" {
		t.Fatalf("activities validated ops = %+v, want exactly the activity-1 op", activities.validatedOps)
	}
	if apiaries.appliedCount() != 1 || !apiaries.applied("apiary-1") {
		t.Fatalf("apiaries applied = %d op(s), want exactly the apiary-1 op", apiaries.appliedCount())
	}
	if activities.appliedCount() != 1 || !activities.applied("activity-1") {
		t.Fatalf("activities applied = %d op(s), want exactly the activity-1 op", activities.appliedCount())
	}
}

// TestCoordinator_Handle_MultiService_MergesApplyResults proves the merged
// response actually carries BOTH services' per-op results back to the
// client — a client watching for its own op's id in the response must see
// it regardless of which owning service applied it.
func TestCoordinator_Handle_MultiService_MergesApplyResults(t *testing.T) {
	apiaries := newStubOwner(t)
	apiaries.applyResults = `{"results":[{"id":"apiary-1","op":"put","result":"applied"}]}`
	activities := newStubOwner(t)
	activities.applyResults = `{"results":[{"id":"activity-1","op":"put","result":"applied"}]}`
	c, err := NewCoordinator(apiaries.server.URL, activities.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	body := []byte(`{"ops":[
		{"op":"put","entity_type":"apiary","id":"apiary-1","updated_at":"2026-07-16T10:00:00Z","data":{}},
		{"op":"put","entity_type":"activity","id":"activity-1","updated_at":"2026-07-16T10:00:00Z","data":{}}
	]}`)
	resp := c.handle(context.Background(), "Bearer tok", body)
	if resp.status != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", resp.status, resp.body)
	}
	var got struct {
		Results []struct {
			ID string `json:"id"`
		} `json:"results"`
	}
	if err := json.Unmarshal(resp.body, &got); err != nil {
		t.Fatalf("decode merged response: %v, body = %s", err, resp.body)
	}
	ids := map[string]bool{}
	for _, r := range got.Results {
		ids[r.ID] = true
	}
	if !ids["apiary-1"] || !ids["activity-1"] {
		t.Fatalf("merged results = %+v, want both apiary-1 and activity-1", got.Results)
	}
}

// TestCoordinator_Handle_MultiService_OneRejectionAppliesNeither is the
// atomicity guarantee (sync.md §6.3): if the activities op fails validation,
// the apiaries op — even though its OWN service would happily validate it —
// must never be applied either. The whole client transaction is one unit of
// intent (sync.md §6.1).
func TestCoordinator_Handle_MultiService_OneRejectionAppliesNeither(t *testing.T) {
	apiaries := newStubOwner(t)
	activities := newStubOwner(t)
	activities.validateStatus = http.StatusUnprocessableEntity
	c, err := NewCoordinator(apiaries.server.URL, activities.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	body := []byte(`{"ops":[
		{"op":"put","entity_type":"apiary","id":"apiary-1","updated_at":"2026-07-16T10:00:00Z","data":{}},
		{"op":"put","entity_type":"activity","id":"activity-1","updated_at":"2026-07-16T10:00:00Z","data":{}}
	]}`)
	resp := c.handle(context.Background(), "Bearer tok", body)
	if resp.status != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (activities rejection must abort the whole push), body = %s", resp.status, resp.body)
	}
	if apiaries.appliedCount() != 0 {
		t.Fatalf("apiaries applied %d op(s), want none — a sibling service's rejection must abort the whole push", apiaries.appliedCount())
	}
	if activities.appliedCount() != 0 {
		t.Fatalf("activities applied %d op(s), want none", activities.appliedCount())
	}
}

// TestCoordinator_Handle_SingleServiceBatch_NeverCallsTheOtherService is the
// common-case regression guard (sync.md §1's "overwhelming majority"): a
// batch with only apiary ops must not touch activitiesURL at all.
func TestCoordinator_Handle_SingleServiceBatch_NeverCallsTheOtherService(t *testing.T) {
	apiaries := newStubOwner(t)
	activities := newStubOwner(t)
	c, err := NewCoordinator(apiaries.server.URL, activities.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	body := []byte(`{"ops":[{"op":"put","entity_type":"apiary","id":"apiary-1","updated_at":"2026-07-16T10:00:00Z","data":{}}]}`)
	resp := c.handle(context.Background(), "Bearer tok", body)
	if resp.status != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", resp.status, resp.body)
	}
	if len(activities.validatedOps) != 0 || activities.appliedCount() != 0 {
		t.Fatalf("activities service was contacted for an apiary-only batch: validated=%+v applied=%d", activities.validatedOps, activities.appliedCount())
	}
}

// TestCoordinator_Handle_MultiService_PartialApplyFailureHealsOnRetry is the
// eventual-consistency regression the design comments assert (sync.md
// §6.2/§6.3): in a multi-service push, group A (apiaries) apply succeeds but
// group B (activities) apply then fails transiently (502) → the client gets
// 502 and the whole batch stays queued. On PowerSync's idempotent
// forward-retry of the SAME batch, group A is re-sent but — because the
// owning service is idempotent on the client UUID PK — does NOT duplicate its
// already-applied op, and group B now succeeds, so the retry completes 200.
func TestCoordinator_Handle_MultiService_PartialApplyFailureHealsOnRetry(t *testing.T) {
	apiaries := newStubOwner(t)
	activities := newStubOwner(t)
	// Group B's apply fails transiently on the first attempt.
	activities.setApplyStatus(http.StatusInternalServerError)
	c, err := NewCoordinator(apiaries.server.URL, activities.server.URL)
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}

	body := []byte(`{"ops":[
		{"op":"put","entity_type":"apiary","id":"apiary-1","updated_at":"2026-07-16T10:00:00Z","data":{}},
		{"op":"put","entity_type":"activity","id":"activity-1","updated_at":"2026-07-16T10:00:00Z","data":{}}
	]}`)

	// First push: apiaries applied apiary-1, activities apply 502 → client 502.
	first := c.handle(context.Background(), "Bearer tok", body)
	if first.status != http.StatusBadGateway {
		t.Fatalf("first push status = %d, want 502 (activities apply failed transiently), body = %s", first.status, first.body)
	}
	if !apiaries.applied("apiary-1") {
		t.Fatalf("apiary-1 should have been applied on the first push (its group's apply succeeded before activities failed)")
	}
	if activities.appliedCount() != 0 {
		t.Fatalf("activities applied %d op(s) on a 502, want 0 (a failed apply commits nothing)", activities.appliedCount())
	}

	// Group B recovers; PowerSync retries the whole batch idempotently.
	activities.setApplyStatus(http.StatusOK)
	second := c.handle(context.Background(), "Bearer tok", body)
	if second.status != http.StatusOK {
		t.Fatalf("retry status = %d, want 200 (the batch heals on forward-retry), body = %s", second.status, second.body)
	}

	// The key property: apiary-1 was NOT duplicated by the retry (the owning
	// service's idempotency on the client UUID PK absorbed the re-send), and
	// activity-1 is now applied exactly once.
	if apiaries.appliedCount() != 1 {
		t.Fatalf("apiaries applied %d distinct op(s) after retry, want 1 — forward-retry must not duplicate an already-applied op", apiaries.appliedCount())
	}
	if apiaries.applyCallCount() != 2 {
		t.Fatalf("apiaries apply was called %d time(s), want 2 (once per push — the coordinator DOES re-send; idempotency lives in the owning service)", apiaries.applyCallCount())
	}
	if activities.appliedCount() != 1 || !activities.applied("activity-1") {
		t.Fatalf("activities applied = %d op(s) after retry, want exactly activity-1", activities.appliedCount())
	}
}
