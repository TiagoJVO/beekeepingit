package dbaccess

import (
	"context"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

// gooseVersionTable is goose's own migration-bookkeeping table (Migrate's
// default; no service calls goose.SetTableName). When a service's DB_SEARCH_PATH
// points at its own schema (as production does, infra/helm's DB_SEARCH_PATH),
// goose creates it inside that same schema — it's a migration-tooling
// artifact, never domain data, so it's always exempt regardless of which
// schema it lands in.
const gooseVersionTable = "goose_db_version"

// UnscopedTables inspects every base table in schema and returns the ones
// that do NOT carry an organization_id column, excluding exemptTables (the
// documented tenancy exceptions — ADR-0002 "tenancy exception": a global
// identity table, or the organizations table itself, which IS the tenant
// root rather than something owned BY a tenant) and goose's own version
// table (never domain data).
//
// This is the automated form of FR-TEN-2 / #30's AC "every owned row carries
// an organization_id": rather than a one-time manual audit, a service's own
// test suite can call this against its migrated schema so a future migration
// that adds an owned table without organization_id fails CI immediately,
// instead of depending on someone remembering to check (data-model.md §5).
func UnscopedTables(ctx context.Context, pool *pgxpool.Pool, schema string, exemptTables ...string) ([]string, error) {
	exempt := map[string]bool{gooseVersionTable: true}
	for _, t := range exemptTables {
		exempt[t] = true
	}

	rows, err := pool.Query(ctx, `
		SELECT t.table_name
		FROM information_schema.tables t
		WHERE t.table_schema = $1
		  AND t.table_type = 'BASE TABLE'
		  AND NOT EXISTS (
		      SELECT 1 FROM information_schema.columns c
		      WHERE c.table_schema = t.table_schema
		        AND c.table_name = t.table_name
		        AND c.column_name = 'organization_id'
		  )
	`, schema)
	if err != nil {
		return nil, fmt.Errorf("dbaccess: query unscoped tables in schema %q: %w", schema, err)
	}
	defer rows.Close()

	var unscoped []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("dbaccess: scan table name: %w", err)
		}
		if !exempt[name] {
			unscoped = append(unscoped, name)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("dbaccess: iterate unscoped tables: %w", err)
	}

	sort.Strings(unscoped)
	return unscoped, nil
}
