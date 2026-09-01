package api

import (
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation/paritytest"
)

// Binds this service's sync-op rules to the shared validation description the
// offline client re-checks queued edits against before pushing (sync.md §9,
// D-12, #584) — see services/shared/syncvalidation/paritytest for why.
func TestSharedValidationDescription_MatchesActivityOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeActivity)

	paritytest.AssertOps(t, e, "put", "patch", "delete")
	// apiary_id/type/occurred_at are required on a put only — PowerSync uploads
	// only the columns that actually changed, so a patch legitimately omits
	// them (#378).
	paritytest.AssertRequiredOn(t, e, "apiary_id", "put")
	paritytest.AssertRequiredOn(t, e, "type", "put")
	paritytest.AssertRequiredOn(t, e, "occurred_at", "put")
	// journey_id is optional on both op kinds; only its form is checked.
	paritytest.AssertRequiredOn(t, e, "journey_id")

	// The per-activity-type attribute schema (ValidateActivity, types.go) stays
	// server-only — it is a rich schema, not a mechanical constraint — but the
	// attribute bag's SHAPE is mirrored, because uploading it as a JSON string
	// instead of an object is the exact bug that reached production (#39).
	paritytest.AssertNoVocabulary(t, e, "type")
	f, ok := e.Field("attributes")
	if !ok || f.Check("jsonObject") == nil {
		t.Fatal("description must keep the attributes-must-be-an-object check (#39)")
	}

	paritytest.AssertDescribesOnlyWireFields(t, e, activityData{})
}
