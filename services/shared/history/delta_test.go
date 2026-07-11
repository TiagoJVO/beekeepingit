package history

import (
	"reflect"
	"sort"
	"testing"
)

func TestComputeChange_Create_BaselineIsFullFields(t *testing.T) {
	updated := map[string]any{"name": "Encosta Nova", "hive_count": int32(0)}

	changedFields, change := ComputeChange(ChangeCreate, nil, updated)

	if changedFields != nil {
		t.Fatalf("create changedFields = %v, want nil", changedFields)
	}
	want := map[string]any{"name": "Encosta Nova", "hive_count": int32(0)}
	if !reflect.DeepEqual(change, want) {
		t.Fatalf("create change = %#v, want %#v", change, want)
	}
}

func TestComputeChange_Create_ReturnsACopyNotAnAlias(t *testing.T) {
	updated := map[string]any{"name": "Encosta Nova"}
	_, change := ComputeChange(ChangeCreate, nil, updated)

	change["name"] = "mutated"
	if updated["name"] != "Encosta Nova" {
		t.Fatalf("mutating the returned baseline mutated the caller's map: %v", updated)
	}
}

func TestComputeChange_Update_OnlyChangedFieldsAppear(t *testing.T) {
	old := map[string]any{"name": "Encosta Nova", "hive_count": int32(0)}
	updated := map[string]any{"name": "Encosta Nova", "hive_count": int32(12)}

	changedFields, change := ComputeChange(ChangeUpdate, old, updated)

	if !reflect.DeepEqual(changedFields, []string{"hive_count"}) {
		t.Fatalf("changedFields = %v, want [hive_count]", changedFields)
	}
	want := map[string]any{"hive_count": FieldChange{From: int32(0), To: int32(12)}}
	if !reflect.DeepEqual(change, want) {
		t.Fatalf("change = %#v, want %#v", change, want)
	}
	if _, ok := change["name"]; ok {
		t.Fatalf("unchanged field %q leaked into the update delta: %#v", "name", change)
	}
}

func TestComputeChange_Update_MultipleFieldsChanged(t *testing.T) {
	old := map[string]any{"name": "A", "hive_count": int32(1)}
	updated := map[string]any{"name": "B", "hive_count": int32(2)}

	changedFields, change := ComputeChange(ChangeUpdate, old, updated)

	sort.Strings(changedFields)
	if !reflect.DeepEqual(changedFields, []string{"hive_count", "name"}) {
		t.Fatalf("changedFields = %v, want [hive_count name]", changedFields)
	}
	if change["name"] != (FieldChange{From: "A", To: "B"}) {
		t.Fatalf("name delta = %#v", change["name"])
	}
	if change["hive_count"] != (FieldChange{From: int32(1), To: int32(2)}) {
		t.Fatalf("hive_count delta = %#v", change["hive_count"])
	}
}

func TestComputeChange_Update_NoFieldsChanged_EmptyDelta(t *testing.T) {
	old := map[string]any{"name": "same", "hive_count": int32(5)}
	updated := map[string]any{"name": "same", "hive_count": int32(5)}

	changedFields, change := ComputeChange(ChangeUpdate, old, updated)

	if len(changedFields) != 0 {
		t.Fatalf("changedFields = %v, want empty", changedFields)
	}
	if len(change) != 0 {
		t.Fatalf("change = %#v, want empty", change)
	}
}

func TestComputeChange_Update_FieldAddedOrRemovedCountsAsChanged(t *testing.T) {
	old := map[string]any{"name": "A"}
	updated := map[string]any{"name": "A", "note": "new field"}

	changedFields, change := ComputeChange(ChangeUpdate, old, updated)

	if !reflect.DeepEqual(changedFields, []string{"note"}) {
		t.Fatalf("changedFields = %v, want [note]", changedFields)
	}
	want := FieldChange{From: nil, To: "new field"}
	if change["note"] != want {
		t.Fatalf("note delta = %#v, want %#v", change["note"], want)
	}
}

func TestComputeChange_Delete_TombstoneOnlyNoFieldValues(t *testing.T) {
	old := map[string]any{"name": "Encosta Nova", "hive_count": int32(12)}

	changedFields, change := ComputeChange(ChangeDelete, old, nil)

	if changedFields != nil {
		t.Fatalf("delete changedFields = %v, want nil", changedFields)
	}
	for _, forbidden := range []string{"name", "hive_count"} {
		if _, ok := change[forbidden]; ok {
			t.Fatalf("delete tombstone leaked field %q: %#v", forbidden, change)
		}
	}
	if deleted, ok := change["deleted"]; !ok || deleted != true {
		t.Fatalf("delete change = %#v, want a deleted:true tombstone marker", change)
	}
}

// TestComputeChange_NeverEmbedsFreeformPersonalDataFields is a pseudonymity
// smoke test at the delta-computation level (history.md §7.3, complementing
// the service-level contract test): ComputeChange is a pure structural
// function — it must not silently rename/allowlist/denylist fields, so a
// caller that (incorrectly) passes an actor's name/email through as a field
// value is a caller bug, not something ComputeChange can detect. This test
// documents that the function is a faithful mirror of whatever map it's
// given, so field-selection discipline is the caller's responsibility.
func TestComputeChange_IsAFaithfulMirrorOfGivenFields(t *testing.T) {
	old := map[string]any{"assignee_id": "11111111-1111-1111-1111-111111111111"}
	updated := map[string]any{"assignee_id": "22222222-2222-2222-2222-222222222222"}

	_, change := ComputeChange(ChangeUpdate, old, updated)

	fc, ok := change["assignee_id"].(FieldChange)
	if !ok {
		t.Fatalf("assignee_id delta = %#v, want a FieldChange", change["assignee_id"])
	}
	if fc.From != old["assignee_id"] || fc.To != updated["assignee_id"] {
		t.Fatalf("assignee_id delta = %#v, want soft IDs preserved verbatim", fc)
	}
}
