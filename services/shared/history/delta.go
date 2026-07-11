package history

import (
	"reflect"
	"sort"
)

// FieldChange is one changed field's before/after value in an update delta
// (history.md §3: `{ field: { from, to } }`).
type FieldChange struct {
	From any `json:"from"`
	To   any `json:"to"`
}

// ComputeChange computes the (changed_fields, change) pair for a create,
// update or delete, from the entity's fields as plain maps — generic over
// any entity, so callers never need a shared struct type. Field values must
// already be the opaque/comparable representation an audit row may safely
// hold (soft IDs, scalars) — callers are responsible for not passing
// denormalized personal data (history.md §7.3).
//
//   - create: old is nil/empty, updated is the entity's initial field
//     values. changedFields is nil; change is the full baseline (updated,
//     verbatim).
//   - update: old and updated are the entity's field maps before/after.
//     Only fields whose value differs appear, keyed by field name, as
//     {from, to}. Fields present in only one map (schema drift) are treated
//     as changed too, using the zero value's absence (nil) for the missing
//     side.
//   - delete: old is the entity's field values at the time of delete,
//     updated is ignored. changedFields is nil; change is just a tombstone
//     marker (no field values — history.md §3 "just the tombstone marker").
//
// Equality is determined with Go's == where possible; values are compared
// via reflect.DeepEqual so this also works for slices/maps/pointers passed
// as field values (e.g. a nullable field represented as *string).
func ComputeChange(changeType string, old, updated map[string]any) (changedFields []string, change map[string]any) {
	switch changeType {
	case ChangeCreate:
		return nil, baseline(updated)
	case ChangeDelete:
		return nil, tombstone()
	case ChangeUpdate:
		return diff(old, updated)
	default:
		// Unknown change types are a caller bug, not a runtime condition to
		// recover from gracefully — surfaced by the empty result rather than
		// a panic, since ComputeChange has no error return (keeps call
		// sites simple; callers only ever pass the three package constants).
		return nil, map[string]any{}
	}
}

// baseline copies updated into a fresh map so callers can't mutate the
// caller's map through the returned Change.
func baseline(updated map[string]any) map[string]any {
	out := make(map[string]any, len(updated))
	for k, v := range updated {
		out[k] = v
	}
	return out
}

// tombstone is the delete marker — no field values, per history.md §3.
func tombstone() map[string]any {
	return map[string]any{"deleted": true}
}

// diff returns the changed field names (sorted for determinism) and the
// {field: {from, to}} payload for every field whose value differs between
// old and updated.
func diff(old, updated map[string]any) ([]string, map[string]any) {
	seen := make(map[string]bool, len(old)+len(updated))
	for k := range old {
		seen[k] = true
	}
	for k := range updated {
		seen[k] = true
	}

	var changedFields []string
	change := make(map[string]any, len(seen))
	for field := range seen {
		oldVal, oldOK := old[field]
		newVal, newOK := updated[field]
		if oldOK && newOK && reflect.DeepEqual(oldVal, newVal) {
			continue
		}
		changedFields = append(changedFields, field)
		change[field] = FieldChange{From: oldVal, To: newVal}
	}
	sort.Strings(changedFields)
	return changedFields, change
}
