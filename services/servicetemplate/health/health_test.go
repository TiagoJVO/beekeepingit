package health_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

func TestHealthz_AlwaysOK(t *testing.T) {
	reg := health.NewRegistry()
	reg.Register("db", func(_ context.Context) error { return errors.New("db down") })

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	reg.Healthz().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d (liveness must not depend on Checkers)", rec.Code, http.StatusOK)
	}
}

func TestReadyz_NoCheckers(t *testing.T) {
	reg := health.NewRegistry()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	reg.Readyz().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestReadyz_PassingChecker(t *testing.T) {
	reg := health.NewRegistry()
	reg.Register("db", func(_ context.Context) error { return nil })

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	reg.Readyz().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestReadyz_FailingChecker(t *testing.T) {
	reg := health.NewRegistry()
	reg.Register("db", func(_ context.Context) error { return errors.New("dial tcp: connection refused") })
	reg.Register("otel", func(_ context.Context) error { return nil })

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	reg.Readyz().ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want %q", ct, "application/problem+json")
	}

	var got problem.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if len(got.Errors) != 1 || got.Errors[0].Field != "db" {
		t.Errorf("Errors = %+v, want exactly one entry naming the failing check %q", got.Errors, "db")
	}
}
