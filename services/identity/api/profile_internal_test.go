package api

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/identity/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// fakeAuditDB is a minimal sqlcgen.DBTX stub that lets a test force
// InsertAuditLog to fail without spinning up a real Postgres container —
// InsertAuditLog is a `:exec` query, so only Exec is ever reached by
// writeProfileAuditLog; Query/QueryRow are unused stand-ins.
type fakeAuditDB struct {
	execErr error
}

func (f *fakeAuditDB) Exec(_ context.Context, _ string, _ ...interface{}) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, f.execErr
}

func (f *fakeAuditDB) Query(_ context.Context, _ string, _ ...interface{}) (pgx.Rows, error) {
	return nil, errors.New("fakeAuditDB: Query not implemented")
}

func (f *fakeAuditDB) QueryRow(_ context.Context, _ string, _ ...interface{}) pgx.Row {
	return nil
}

// TestWriteProfileAuditLog_InsertFailure_WrapsErrorWithContext is the
// regression test for the code-review HIGH #2 finding: writeProfileAuditLog
// used to return q.InsertAuditLog's error raw/unwrapped, breaking this
// module's own error-wrapping convention (main.go, store/seed.go both use
// fmt.Errorf("...: %w", err)). Before the fix this test fails on the
// strings.Contains assertion because the returned error is exactly
// insertErr, with no added context.
func TestWriteProfileAuditLog_InsertFailure_WrapsErrorWithContext(t *testing.T) {
	insertErr := errors.New("insert boom")
	q := sqlcgen.New(&fakeAuditDB{execErr: insertErr})

	entityID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	actorID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	after := sqlcgen.IdentityUser{Name: "Ana", Email: "ana@example.com", Locale: "en"}

	err := writeProfileAuditLog(context.Background(), q, entityID, actorID, history.ChangeCreate, sqlcgen.IdentityUser{}, after)
	if err == nil {
		t.Fatal("writeProfileAuditLog with a failing InsertAuditLog succeeded, want an error")
	}
	if !errors.Is(err, insertErr) {
		t.Fatalf("error = %v, want it to wrap the underlying InsertAuditLog error (%v)", err, insertErr)
	}
	if !strings.Contains(err.Error(), "insert profile audit log:") {
		t.Fatalf("error = %q, want it prefixed with \"insert profile audit log:\" per this module's error-wrapping convention", err.Error())
	}
}
