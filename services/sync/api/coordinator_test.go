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
				c, err = NewCoordinator("http://127.0.0.1:1")
				if err != nil {
					t.Fatalf("NewCoordinator: %v", err)
				}
			} else {
				stub = newStubApiaries(t)
				stub.validateStatus = tc.validateStatus
				stub.applyStatus = tc.applyStatus
				var err error
				c, err = NewCoordinator(stub.server.URL)
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
	c, err := NewCoordinator(stub.server.URL)
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
	c, err := NewCoordinator("http://127.0.0.1:1")
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

	c, err := NewCoordinator(server.URL)
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

	c, err := NewCoordinator(server.URL)
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
// INTERNAL_APIARIES_URL with a trailing slash must not produce a
// double-slash path when concatenated with "/internal/sync/...".
func TestNewCoordinator_TrimsTrailingSlash(t *testing.T) {
	c, err := NewCoordinator("http://apiaries.internal.svc/")
	if err != nil {
		t.Fatalf("NewCoordinator: %v", err)
	}
	if c.apiariesURL != "http://apiaries.internal.svc" {
		t.Errorf("apiariesURL = %q, want %q (trailing slash trimmed)", c.apiariesURL, "http://apiaries.internal.svc")
	}
}
