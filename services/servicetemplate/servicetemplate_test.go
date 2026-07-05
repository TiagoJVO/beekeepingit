package servicetemplate_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestNew_RequiresServiceName(t *testing.T) {
	_, err := servicetemplate.New(config.Config{}, nil, testLogger(), nil)
	if err == nil {
		t.Fatal("New() error = nil, want error for missing ServiceName")
	}
}

func TestNew_HealthzAndReadyz(t *testing.T) {
	srv, err := servicetemplate.New(config.Config{ServiceName: "example", HTTPAddr: ":0"}, nil, testLogger(), nil)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	for _, path := range []string{"/healthz", "/readyz"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		srv.Router().ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("%s status = %d, want %d", path, rec.Code, http.StatusOK)
		}
	}
}

func TestNew_ReadyzReflectsFailingCheck(t *testing.T) {
	checks := health.NewRegistry()
	checks.Register("db", func(_ context.Context) error { return errors.New("down") })
	srv, err := servicetemplate.New(config.Config{ServiceName: "example", HTTPAddr: ":0"}, nil, testLogger(), checks)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
}

func TestMount_ServesMountedHandler(t *testing.T) {
	srv, err := servicetemplate.New(config.Config{ServiceName: "example", HTTPAddr: ":0"}, nil, testLogger(), nil)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	srv.Mount("/v1/example-items", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/example-items", nil)
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusTeapot {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusTeapot)
	}
}

func TestRun_GracefulShutdownOnContextCancel(t *testing.T) {
	srv, err := servicetemplate.New(config.Config{ServiceName: "example", HTTPAddr: "127.0.0.1:0"}, nil, testLogger(), nil)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- srv.Run(ctx) }()

	time.Sleep(50 * time.Millisecond) // let the listener start
	cancel()

	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Run() error = %v, want nil after graceful shutdown", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run() did not return within 5s after context cancellation")
	}
}
