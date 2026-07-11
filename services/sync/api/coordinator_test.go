package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
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

func TestCoordinator_ValidateThenApply_Success(t *testing.T) {
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
	if atomic.LoadInt32(&stub.validateHits) != 1 || atomic.LoadInt32(&stub.applyHits) != 1 {
		t.Errorf("hits: validate=%d apply=%d, want 1/1", stub.validateHits, stub.applyHits)
	}
	if atomic.LoadInt32(&stub.sawBearer) != 1 {
		t.Error("bearer was not forwarded upstream")
	}
}

func TestCoordinator_ValidateReject_Relays422_WithoutApplying(t *testing.T) {
	stub := newStubApiaries(t)
	stub.validateStatus = http.StatusUnprocessableEntity
	c, _ := NewCoordinator(stub.server.URL)

	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if resp.status != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422", resp.status)
	}
	if atomic.LoadInt32(&stub.applyHits) != 0 {
		t.Errorf("apply was called %d times on a validation reject, want 0", stub.applyHits)
	}
}

func TestCoordinator_ApplyTransientFailure_502(t *testing.T) {
	stub := newStubApiaries(t)
	stub.applyStatus = http.StatusInternalServerError
	c, _ := NewCoordinator(stub.server.URL)

	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if resp.status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.status)
	}
}

func TestCoordinator_UpstreamDown_502(t *testing.T) {
	// A URL with nothing listening — the validate call errors.
	c, _ := NewCoordinator("http://127.0.0.1:1")
	resp := c.handle(context.Background(), "Bearer tok", []byte(`{"ops":[]}`))
	if resp.status != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.status)
	}
}
