package problem_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

func TestWrite(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/apiaries/123", nil)

	problem.Write(rec, req, problem.NotFound("apiary not found"))

	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want %q", ct, "application/problem+json")
	}
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}

	var got problem.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if got.Code != "resource.not_found" {
		t.Errorf("Code = %q, want %q", got.Code, "resource.not_found")
	}
	if got.Instance != "/v1/apiaries/123" {
		t.Errorf("Instance = %q, want request path %q", got.Instance, "/v1/apiaries/123")
	}
}

func TestConstructors_Status(t *testing.T) {
	cases := []struct {
		name string
		p    problem.Problem
		want int
	}{
		{"Unauthorized", problem.Unauthorized("no token"), http.StatusUnauthorized},
		{"Forbidden", problem.Forbidden("not allowed"), http.StatusForbidden},
		{"NotFound", problem.NotFound("missing"), http.StatusNotFound},
		{"Conflict", problem.Conflict("stale etag"), http.StatusConflict},
		{"ValidationFailed", problem.ValidationFailed("bad input"), http.StatusUnprocessableEntity},
		{"Internal", problem.Internal(), http.StatusInternalServerError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.p.Status != tc.want {
				t.Errorf("Status = %d, want %d", tc.p.Status, tc.want)
			}
			if tc.p.Code == "" {
				t.Error("Code is empty, want a stable machine code")
			}
		})
	}
}

func TestValidationFailed_CarriesFieldErrors(t *testing.T) {
	p := problem.ValidationFailed("hive_count must be >= 0", problem.FieldError{
		Field: "hive_count", Code: "out_of_range", Message: "Must be 0 or more.",
	})
	if len(p.Errors) != 1 || p.Errors[0].Field != "hive_count" {
		t.Errorf("Errors = %+v, want one FieldError for hive_count", p.Errors)
	}
}

func TestInternal_NeverLeaksDetail(t *testing.T) {
	if got := problem.Internal().Detail; got != "an unexpected error occurred" {
		t.Errorf("Internal().Detail = %q, want a fixed generic message", got)
	}
}

func TestRecoverMiddleware_CatchesPanic(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	panicking := http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		panic("boom")
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/apiaries", nil)
	problem.RecoverMiddleware(logger)(panicking).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
	var got problem.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if got.Code != "internal.error" {
		t.Errorf("Code = %q, want %q", got.Code, "internal.error")
	}
}

func TestRecoverMiddleware_PassesThroughWithoutPanic(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	problem.RecoverMiddleware(logger)(ok).ServeHTTP(rec, req)

	if rec.Code != http.StatusTeapot {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusTeapot)
	}
}

// TestRecoverMiddleware_RePanicsOnErrAbortHandler is a regression test: a
// handler that intentionally aborts a streamed/partial response via
// http.ErrAbortHandler (the documented net/http mechanism for that) must
// NOT be converted into a 500 problem+json body — net/http specifically
// suppresses its own panic logging for this sentinel and expects it to
// keep propagating so the connection is simply closed.
func TestRecoverMiddleware_RePanicsOnErrAbortHandler(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	aborting := http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		panic(http.ErrAbortHandler)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/apiaries", nil)

	var recovered any
	func() {
		defer func() { recovered = recover() }()
		problem.RecoverMiddleware(logger)(aborting).ServeHTTP(rec, req)
	}()

	if recovered != http.ErrAbortHandler {
		t.Fatalf("recovered = %v, want %v (ErrAbortHandler must propagate, not be swallowed)", recovered, http.ErrAbortHandler)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("response body = %q, want empty (no Write(w, r, Internal()) for an aborted response)", rec.Body.String())
	}
}
