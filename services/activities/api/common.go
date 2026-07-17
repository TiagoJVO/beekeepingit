// Package api (this file) — shared helpers for the activities service's HTTP
// surface. #38 deliberately exposes only a thin internal validate endpoint
// (validate.go): the create/edit/delete/list REST + sync-apply surface is
// #39 and later stories' scope (see this package's doc comment in types.go
// and the PR description for the full rationale). requireOrg/writeJSON below
// mirror services/apiaries/api/common.go's own helpers so the wiring pattern
// #39 needs (JWT + org-resolver + role, RFC 9457 responses) is already
// established and tested here.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/activities/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const entityTypeActivity = "activity"

// requireOrg is the tenancy-context hand-off point (FR-TEN-2), mirroring
// apiaries/api/common.go's helper of the same name: it pulls the org id
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
// transaction abort quietly." Mirrors services/apiaries/api/common.go's
// identical helper.
var errResponseWritten = errors.New("activities: response already written")

// withTx runs fn inside one pool transaction: begins, always defers a
// rollback (a no-op after a successful commit), and commits iff fn returns
// nil. Mirrors services/apiaries/api/common.go's withTx.
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

// isUniqueViolation reports whether err is a Postgres unique_violation
// (SQLSTATE 23505) — the client-generated id already exists. Mirrors
// services/apiaries/api/write.go's helper of the same name/purpose.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
