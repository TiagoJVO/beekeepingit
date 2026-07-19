// Package api (this file) — shared helpers for the todos service's HTTP
// surface (#50, FR-TD-1, FR-TEN-2). requireOrg/writeJSON/withTx below mirror
// services/activities/api/common.go's own helpers verbatim (this repo's
// five domain services all wire the same JWT + org-resolver + role,
// RFC 9457 response pattern — see that file's own doc comment for the full
// rationale).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/todos/store/sqlc/gen"
)

const entityTypeTodo = "todo"

// requireOrg is the tenancy-context hand-off point (FR-TEN-2), mirroring
// activities/api/common.go's helper of the same name: it pulls the org id
// authn.NewOrgResolver already derived server-side from the verified token +
// membership (never a client-supplied header/body/query value) off the
// request's Claims. The org-resolver middleware guarantees these are
// present; a missing value is a wiring bug, surfaced as 500.
func requireOrg(w http.ResponseWriter, r *http.Request) (orgID pgtype.UUID, userID string, ok bool) {
	claims, found := authn.FromContext(r.Context())
	if !found || claims.OrganizationID == "" {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "requireOrg: missing claims or empty organization_id (wiring bug: org-resolver middleware should guarantee these)")
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, "", false
	}
	parsed, err := uuid.Parse(claims.OrganizationID)
	if err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "requireOrg: organization_id claim is not a valid UUID", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, "", false
	}
	return pgtype.UUID{Bytes: parsed, Valid: true}, claims.UserID, true
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		logging.FromContext(r.Context()).WarnContext(r.Context(), "write json response: encode failed", slog.Any("error", err))
	}
}

// errResponseWritten is withTx's sentinel for "the transaction function
// already wrote the HTTP response itself (a domain-expected outcome like
// 404/409, not an unexpected internal error) — the caller must not also log
// it or write a second (problem.Internal) response, just let the
// transaction abort quietly." Mirrors activities/api/common.go's identical
// helper.
var errResponseWritten = errors.New("todos: response already written")

// withTx runs fn inside one pool transaction: begins, always defers a
// rollback (a no-op after a successful commit), and commits iff fn returns
// nil. Mirrors activities/api/common.go's withTx.
func withTx(ctx context.Context, pool *pgxpool.Pool, fn func(*sqlcgen.Queries) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after a successful Commit
	if err := fn(sqlcgen.New(tx)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

// timePtr reads a nullable pgtype.Timestamptz column back as a *time.Time
// (nil when unset) — used by sync.go's logTodoConflict to include a
// tombstoned row's deleted_at in its winning-payload snapshot. Mirrors
// activities/api/common.go's helper of the same name/purpose.
func timePtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}

// isUniqueViolation reports whether err is a Postgres unique_violation
// (SQLSTATE 23505) — the client-generated id already exists. Mirrors
// activities/api/common.go's helper of the same name/purpose.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// parseActor resolves userID (the caller's resolved user id) to the
// nullable pgtype.UUID audit_log/sync_conflict_log's actor_user_id column
// expects. Mirrors activities/api/sync.go's helper of the same name/purpose.
func parseActor(ctx context.Context, userID string) pgtype.UUID {
	u, err := uuid.Parse(userID)
	if err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "parseActor: userID is not a valid UUID; audit actor will be recorded as NULL", slog.Any("error", err))
		return pgtype.UUID{Valid: false}
	}
	return pgtype.UUID{Bytes: u, Valid: true}
}

// dateLayout is the plain YYYY-MM-DD wire/storage format for due_date — no
// time-of-day component, matching activities' own occurred_at convention
// (services/activities/api/validate.go's dateLayout).
const dateLayout = "2006-01-02"

// textOf reads a nullable pgtype.Text column back as a plain string, "" when
// unset — mirrors services/apiaries/api/common.go's textOf, the established
// convention for todos' own nullable free-text (description) column: "" is
// always treated as "no value", so the DB's NULL and an explicit empty
// string are indistinguishable at this layer by design (never a
// meaningfully different domain state for free text).
func textOf(t pgtype.Text) string {
	if !t.Valid {
		return ""
	}
	return t.String
}

// textParam is textOf's inverse: builds a pgtype.Text that is NULL for an
// empty string, set otherwise. Mirrors apiaries' notesParamFromState.
func textParam(s string) pgtype.Text {
	if s == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: s, Valid: true}
}

// dateOf reads a nullable pgtype.Date column back as a plain YYYY-MM-DD
// string, "" when unset (todos' due_date, FR-TD-1: "a todo may legitimately
// have none").
func dateOf(d pgtype.Date) string {
	if !d.Valid {
		return ""
	}
	return d.Time.Format(dateLayout)
}

// dateParam is dateOf's inverse: parses a YYYY-MM-DD string into a
// pgtype.Date, NULL for an empty string. Callers must have already
// validated the format (validateTodoCreate/validateTodoUpdate/validateTodoOp).
func dateParam(s string) (pgtype.Date, error) {
	if s == "" {
		return pgtype.Date{}, nil
	}
	t, err := time.Parse(dateLayout, s)
	if err != nil {
		return pgtype.Date{}, err
	}
	return pgtype.Date{Time: t, Valid: true}, nil
}

// timestampOf reads a nullable pgtype.Timestamptz column back as an
// RFC3339Nano string, "" when unset — todos' own completed_at convention
// (cleared on reopen), following the same "" sentinel pattern as
// textOf/dateOf above.
func timestampOf(ts pgtype.Timestamptz) string {
	if !ts.Valid {
		return ""
	}
	return ts.Time.UTC().Format(time.RFC3339Nano)
}

// timestampParam is timestampOf's inverse: parses an RFC3339 string into a
// pgtype.Timestamptz, NULL for an empty string. Used by sync.go when
// applying a queued complete/reopen patch's completed_at field.
func timestampParam(s string) (pgtype.Timestamptz, error) {
	if s == "" {
		return pgtype.Timestamptz{}, nil
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return pgtype.Timestamptz{}, err
	}
	return pgtype.Timestamptz{Time: t, Valid: true}, nil
}

// uuidOf reads a nullable pgtype.UUID column back as a plain string, "" when
// unset — todos' own assignee_id convention (D-23: optional, default
// unassigned), mirroring textOf's "" sentinel for the same reason: an unset
// cross-service soft reference has no meaningfully different NULL-vs-absent
// state at this layer.
func uuidOf(u pgtype.UUID) string {
	if !u.Valid {
		return ""
	}
	return uuidString(u)
}

// uuidParam is uuidOf's inverse: parses a UUID string into a pgtype.UUID,
// NULL for an empty string. Callers must have already validated the format.
func uuidParam(s string) (pgtype.UUID, error) {
	if s == "" {
		return pgtype.UUID{}, nil
	}
	id, err := uuid.Parse(s)
	if err != nil {
		return pgtype.UUID{}, err
	}
	return pgtype.UUID{Bytes: id, Valid: true}, nil
}
