// Package history is the shared cross-cutting contract for append-only,
// per-entity change history (FR-HIS-1, NFR-CMP-1), per
// docs/architecture/history.md §3-§4. It is deliberately NOT a data-access
// layer: ownership rule 1 (service-decomposition.md §4, "a service writes
// only its own schema") means a shared library can never hold a DB
// connection spanning services, so it cannot own a cross-schema audit_log
// table the way dbaccess owns connections.
//
// What IS shared: the row-shape (Entry) every service's own audit_log
// mirrors, and the pure delta-computation logic (ComputeChange) that turns
// an old/new field map into the create/update/delete payload history.md §3
// defines. Each owning service still declares its own audit_log
// table/migration/sqlc query in its own schema (apiaries.audit_log,
// activities.audit_log, ...) and calls ComputeChange to build the row it
// inserts in the same local transaction as its domain write (history.md §4).
//
// This package must stay entity-agnostic: nothing here may hardcode a
// specific service's fields or entity_type, so #165 (identity/organizations
// history) can reuse it unchanged.
package history

import "time"

// Change types (history.md §3's change_type column).
const (
	ChangeCreate = "create"
	ChangeUpdate = "update"
	ChangeDelete = "delete"
)

// Entry mirrors the audit_log row shape fixed by history.md §3. It is a
// plain value type — building one is free of any DB/service concern; each
// service's sqlc InsertAuditLog query consumes its fields directly.
//
// Fields carry only opaque IDs (OrganizationID, EntityID, ActorUserID) and a
// delta payload built from IDs, never denormalized personal data (§7.3) —
// callers must not put names/emails into Change.
type Entry struct {
	// OrganizationID scopes the row to a tenant (FR-TEN-2). Every audit row
	// is org-scoped consistently with the entity it describes.
	OrganizationID string
	// EntityType is the polymorphic discriminator (e.g. "apiary"); a soft
	// reference, no cross-schema FK (history.md §3).
	EntityType string
	// EntityID is a soft reference to the changed row.
	EntityID string
	// ChangeType is one of ChangeCreate, ChangeUpdate, ChangeDelete.
	ChangeType string
	// ActorUserID is the internal user UUID only — never denormalized actor
	// PII (§7.3). Resolved to a display name by joining identity.users at
	// read time, never stored here.
	ActorUserID string
	// OccurredAt is the device time the change was made (offline-correct,
	// §6) — the op's device timestamp, not the server receive time.
	OccurredAt time.Time
	// RecordedAt is the server time the change was applied/committed.
	// Callers normally leave this to the database's DEFAULT now() on
	// INSERT; it is here for callers that need to set it explicitly (e.g.
	// tests asserting recorded_at is close to "now").
	RecordedAt time.Time
	// ChangedFields is, on update, the columns that changed (drives the
	// timeline UI). Empty for create/delete.
	ChangedFields []string
	// Change is the delta payload (§3): baseline field values on create,
	// {field: {from, to}} for changed columns only on update, a tombstone
	// marker on delete. Produced by ComputeChange.
	Change map[string]any
}
