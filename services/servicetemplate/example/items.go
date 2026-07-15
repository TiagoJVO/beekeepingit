package main

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/shared/dbaccess/sqlc/gen"
)

// itemsHandler demonstrates the template's Postgres data-access layer: it
// reuses services/shared/dbaccess's platform_example.items reference table
// and typed queries rather than inventing a new fake domain model. The
// response is a plain array — illustrative only; real domain endpoints
// follow docs/architecture/api-contracts.md's cursor-paginated Page
// envelope.
//
// db is sqlcgen.DBTX rather than a concrete *pgxpool.Pool so the DB-failure
// path below is unit-testable with a fake DBTX; *pgxpool.Pool still
// satisfies this interface, so callers are unaffected.
//
// This is the literal reference every domain service's own handlers are
// copy-pasted from: a DB error is always logged server-side (never silently
// dropped) before returning the standard generic 500 problem+json body — the
// raw driver error must never reach the client.
func itemsHandler(db sqlcgen.DBTX) http.HandlerFunc {
	queries := sqlcgen.New(db)
	return func(w http.ResponseWriter, r *http.Request) {
		items, err := queries.ListItems(r.Context())
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list items failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(items)
	}
}
