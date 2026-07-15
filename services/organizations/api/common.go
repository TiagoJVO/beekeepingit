package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
)

// writeJSON encodes v as the response body with status. An encode failure is
// logged rather than silently discarded — by this point WriteHeader has
// already been called, so it can't be turned into a different response, only
// recorded server-side for diagnosis.
func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "encode JSON response failed", slog.Any("error", err))
	}
}

func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

// withTx runs fn inside a new transaction on pool, committing on success.
// Rollback is always deferred (a no-op after a successful Commit) so a
// handler returning early on any error never leaves the transaction open.
// Factored out of createOrganization/createInvitationHandler/
// revokeInvitationHandler/acceptPendingInvitationByEmail, which were each
// repeating this same Begin/defer Rollback/Commit boilerplate around their
// own domain-write-plus-#165-audit-log body.
func withTx(ctx context.Context, pool *pgxpool.Pool, fn func(pgx.Tx) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after a successful Commit
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}
