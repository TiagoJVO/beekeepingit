package health_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
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

// TestReadyz_FailingChecker_DoesNotLeakRawError is a regression test for the
// /readyz endpoint embedding a checker's raw error text (e.g. a Postgres DSN
// with host/port/user) directly in an unauthenticated HTTP response.
func TestReadyz_FailingChecker_DoesNotLeakRawError(t *testing.T) {
	reg := health.NewRegistry()
	sensitive := "dial tcp 10.0.5.12:5432: connect: connection refused (user=admin dbname=beekeepingit)"
	reg.Register("db", func(_ context.Context) error { return errors.New(sensitive) })

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	reg.Readyz().ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
	if strings.Contains(rec.Body.String(), sensitive) {
		t.Fatalf("response body leaks the raw checker error verbatim: %s", rec.Body.String())
	}

	var got problem.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if len(got.Errors) != 1 || got.Errors[0].Field != "db" {
		t.Fatalf("Errors = %+v, want exactly one entry naming db", got.Errors)
	}
	if got.Errors[0].Message == "" || got.Errors[0].Message == sensitive {
		t.Errorf("Errors[0].Message = %q, want a fixed generic message, not the raw error", got.Errors[0].Message)
	}
}

// TestReadyz_FailingChecker_LogsRawErrorServerSide proves the raw checker
// error is not simply discarded once it stops going in the HTTP response —
// an operator still needs it, just server-side instead of client-visible.
func TestReadyz_FailingChecker_LogsRawErrorServerSide(t *testing.T) {
	var buf bytes.Buffer
	prevDefault := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prevDefault) })

	reg := health.NewRegistry()
	sensitive := "dial tcp 10.0.5.12:5432: connect: connection refused"
	reg.Register("db", func(_ context.Context) error { return errors.New(sensitive) })

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	reg.Readyz().ServeHTTP(rec, req)

	if !strings.Contains(buf.String(), sensitive) {
		t.Errorf("server-side log missing the raw checker error; got: %s", buf.String())
	}
}
