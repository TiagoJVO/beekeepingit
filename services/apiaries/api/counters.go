// Package api (this file) — apiary_counters: typed 1-N counters decoupled
// from the apiaries table (#256, FR-AP-7, D-2 note on current-state counters
// vs activity-attribute events, the 2026-07-13 user decision recorded as the
// next D-* in requirements/decisions.md). One row per (apiary, counter_type),
// enforced by the table's UNIQUE(apiary_id, counter_type) constraint
// (00005_create_apiary_counters.sql) — an apiary can never hold two counters
// of the same type.
//
// counter_type is validated here, in the OWNING SERVICE, against a known set
// — NOT a DB enum/CHECK — so adding a future type (nucs, supers, queens, ...)
// is a code-only append to knownCounterTypes, mirroring the data-model.md §2
// "Extensible enums" convention already used for activity `type`/membership
// `role`. The client mirrors the same known set
// (client/lib/features/apiaries/counter_types.dart) so the detail screen's
// "render every known type, hive always" behavior stays in lockstep.
//
// Two write paths reach apiary_counters, both wired in sync.go:
//   - the legacy entityTypeApiary op's `hive_count` field (apiaryData) —
//     kept fully functional for wire-shape/test compatibility (REST
//     apiaryDTO.HiveCount and the sync `apiary` op both still read/write
//     the hive counter transparently, so no existing caller/test needed to
//     change), applyOp/write.go's create/updateApiary upsert it internally;
//   - the new, real 1-N entityTypeApiaryCounter op (sync.go's
//     applyCounterOp) — the client's actual write path going forward
//     (client/lib/features/apiaries/apiaries_repository.dart), keyed by
//     (apiary_id, counter_type) rather than a client-generated row id, since
//     that id is only the local row's own PK, never the server's identity
//     for a counter row.
package api

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
)

const (
	// counterTypeHive is the always-present counter type (#256 AC 1: "New
	// apiary_counters table... counter_type from a known set (initially
	// hive)"). A future type is added by appending a new const here and to
	// knownCounterTypes below — no apiaries-table migration, per the AC.
	counterTypeHive = "hive"
	// counterTypeSuper (Portuguese "alças") is the second known countable
	// (#346, D-20 names "nucs, supers, queens" as examples; supers is the one
	// the Melargil prototype's apiary detail already surfaces). Its addition
	// is exactly the "code-only append to the known set" D-20 promises — a
	// const here + a knownCounterTypes entry, mirrored in the client's
	// counter_types.dart, with no schema migration.
	counterTypeSuper = "super"
	// counterTypeEmptyHive is a hive box present at the apiary with no active
	// colony (#392). Mirrored in the client's counter_types.dart.
	counterTypeEmptyHive = "empty_hive"
	// counterTypeSwarm (Portuguese "enxames") is a captured/hived swarm, distinct
	// from counterTypeHive: a captured colony not yet established as a counted
	// hive (#392). Mirrored in the client's counter_types.dart.
	counterTypeSwarm = "swarm"
)

// knownCounterTypes is the extensible set counter_type is validated against
// (#256 AC 2: "Adding a future counter type = appending to the known set...
// with no apiaries-table migration"). validateCounterOp (sync.go) rejects
// anything outside this set with the standard RFC 9457 error format.
var knownCounterTypes = map[string]bool{
	counterTypeHive:      true,
	counterTypeSuper:     true,
	counterTypeEmptyHive: true,
	counterTypeSwarm:     true,
}

// isKnownCounterType reports whether t is in the known, server-validated set
// (#256 AC 2).
func isKnownCounterType(t string) bool {
	return knownCounterTypes[t]
}

// upsertCounter writes value for (org, apiaryID, counterType) via the
// table's ON CONFLICT (apiary_id, counter_type) upsert (#256 AC: "enforce
// the uniqueness by upsert semantics") — never a check-then-insert/update
// pair, so it is safe under two writers targeting the same counter
// concurrently (e.g. two offline devices both editing the same apiary's
// hive count) without an application-level lock. Called by every write path
// that touches a counter (sync.go's applyOp/applyCounterOp,
// write.go's createApiary/updateApiary) in the SAME local transaction as
// its triggering domain write, via the shared *Queries built from that
// transaction's pgx.Tx — so an apiary row and its hive counter always
// commit or roll back together.
func upsertCounter(ctx context.Context, q *sqlcgen.Queries, org pgtype.UUID, apiaryID pgtype.UUID, counterType string, value int32, updatedAt pgtype.Timestamptz) error {
	_, err := q.UpsertApiaryCounter(ctx, sqlcgen.UpsertApiaryCounterParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		OrganizationID: org,
		ApiaryID:       apiaryID,
		CounterType:    counterType,
		Value:          value,
		UpdatedAt:      updatedAt,
	})
	return err
}
