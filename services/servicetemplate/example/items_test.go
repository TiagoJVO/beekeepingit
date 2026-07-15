package main

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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// failingDB is a minimal sqlcgen.DBTX stand-in whose Query call always fails,
// standing in for a real Postgres failure (connection reset, statement
// timeout, etc.) without needing a live database in this unit test.
type failingDB struct{ err error }

func (f failingDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, f.err
}

func (f failingDB) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, f.err
}

func (f failingDB) QueryRow(context.Context, string, ...any) pgx.Row {
	return nil
}

// TestItemsHandler_DBFailure_LogsAndReturnsGenericProblem is a regression
// test for the reference handler every domain service's own handlers are
// copy-pasted from: a DB failure must be logged server-side (so it's
// diagnosable) and must still return the standard generic 500 problem+json
// body — the raw driver error must never reach the client.
func TestItemsHandler_DBFailure_LogsAndReturnsGenericProblem(t *testing.T) {
	sensitive := "dial tcp 10.0.5.12:5432: connect: connection reset by peer"
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil))

	handler := logging.RequestLogger(logger)(itemsHandler(failingDB{err: errors.New(sensitive)}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/example-items", nil)
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d, body = %s", rec.Code, http.StatusInternalServerError, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want application/problem+json", ct)
	}
	if strings.Contains(rec.Body.String(), sensitive) {
		t.Fatalf("response body leaks the raw DB error verbatim: %s", rec.Body.String())
	}

	var got problem.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if got.Code != "internal.error" {
		t.Errorf("Code = %q, want %q", got.Code, "internal.error")
	}

	if !strings.Contains(buf.String(), sensitive) {
		t.Errorf("DB failure was not logged server-side; log output: %s", buf.String())
	}
	if !strings.Contains(buf.String(), "list items failed") {
		t.Errorf("log output missing a descriptive message; got: %s", buf.String())
	}
}
