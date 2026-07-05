package main

import (
	"encoding/json"
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/shared/dbaccess/sqlc/gen"
)

// itemsHandler demonstrates the template's Postgres data-access layer: it
// reuses services/shared/dbaccess's platform_example.items reference table
// and typed queries rather than inventing a new fake domain model. The
// response is a plain array — illustrative only; real domain endpoints
// follow docs/architecture/api-contracts.md's cursor-paginated Page
// envelope.
func itemsHandler(pool *pgxpool.Pool) http.HandlerFunc {
	queries := sqlcgen.New(pool)
	return func(w http.ResponseWriter, r *http.Request) {
		items, err := queries.ListItems(r.Context())
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(items)
	}
}
