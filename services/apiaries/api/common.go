// Package api holds the apiaries service's HTTP surface: the client-facing
// REST endpoints (GET/POST/PATCH/DELETE /v1/apiaries[/{id}], apiaries.go +
// write.go, #31/FR-AP-1) and the internal sync validate/apply endpoints the
// write-back coordinator calls (walking-skeleton.md §5, sync.go). The field
// client never calls the REST write handlers directly — it is local-first
// through sync (§4.4); the REST writes serve online-only/direct callers.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const entityTypeApiary = "apiary"

// entityTypeApiaryCounter is the sync-apply entity_type for apiary_counters
// rows (#256) — a second, parallel entity_type the same batch endpoint
// accepts alongside entityTypeApiary (sync.go's validateOp/applyOp branch on
// it), so a client transaction can freely mix apiary and counter ops in one
// push. Kept as its own constant (not inlined) since it appears in both
// sync.go (validate/apply) and history/conflict-log rows.
const entityTypeApiaryCounter = "apiary_counter"

// requireOrg is the tenancy-context hand-off point (FR-TEN-2, #30 AC:
// "a tenancy context is propagated from the validated token through the
// service layer to the data layer"): it pulls the org id
// authn.NewOrgResolver already derived server-side from the verified
// token + membership (never a client-supplied header/body/query value) off
// the request's Claims, parses it once, and every handler in this package
// passes the result straight into its sqlc query's OrganizationID param —
// the one point where "token claim" becomes "data-layer filter". The
// org-resolver middleware guarantees these are present; a missing value is
// a wiring bug, surfaced as 500.
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
		// The status code and headers are already flushed, so nothing can be
		// done about it at this point for THIS response — but it must not
		// vanish silently (e.g. a client disconnecting mid-write, or a value
		// that fails to marshal, both worth knowing about).
		logging.FromContext(r.Context()).WarnContext(r.Context(), "write json response: encode failed", slog.Any("error", err))
	}
}

// errResponseWritten is withTx's sentinel for "the transaction function
// already wrote the HTTP response itself (a domain-expected outcome like
// 404/409/idempotent-conflict, not an unexpected internal error) — the
// caller must not also log it or write a second (problem.Internal) response,
// just let the transaction abort quietly."
var errResponseWritten = errors.New("apiaries: response already written")

// withTx runs fn inside one pool transaction: begins, always defers a
// rollback (a no-op after a successful commit), and commits iff fn returns
// nil. Extracted from createApiary/updateApiary/deleteApiary/applyBatch,
// which all repeated this exact begin/rollback/commit dance (HIGH: large,
// duplicated write-handler functions) — this is also the one place callers
// need to log a tx-related failure (HIGH: internal errors discarded before a
// generic 500, never logged): every caller logs once, after withTx returns a
// non-errResponseWritten error, rather than at each individual
// problem.Internal() call site the old duplicated code had.
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

// textPtr converts a nullable pgtype.Text column (e.g. apiaries.notes) to the
// DTO's *string — nil when unset, matching Location's own
// present-vs-absent convention (apiaryDTO's `omitempty`).
func textPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	return &t.String
}
