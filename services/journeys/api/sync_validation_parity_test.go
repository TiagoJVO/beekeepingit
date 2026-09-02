package api

import (
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation/paritytest"
)

// Binds this service's sync-op rules to the shared validation description the
// offline client re-checks queued edits against before pushing (sync.md §9,
// D-12, #584) — see services/shared/syncvalidation/paritytest for why.
func TestSharedValidationDescription_MatchesJourneyOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeJourney)

	paritytest.AssertOps(t, e, "put", "patch", "delete")
	// name/main_activity_type are required on a put only — a status-only
	// "close journey" patch is the concrete case (#378).
	paritytest.AssertRequiredOn(t, e, "name", "put")
	paritytest.AssertRequiredOn(t, e, "main_activity_type", "put")
	paritytest.AssertLimit(t, e, "name", "maxLength", maxNameLength)
	// validateJourneyOp guards name with `nil || ""`; main_activity_type and
	// status on nil alone (an empty string is a value that fails the vocabulary
	// check server-side, not an absent field).
	paritytest.AssertAbsentWhen(t, e, "name", paritytest.AbsentEmpty)
	paritytest.AssertAbsentWhen(t, e, "main_activity_type", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "default_attributes", paritytest.AbsentNull)

	// default_attributes' SHAPE is mirrored (object + byte cap,
	// validateDefaultAttributes) — uploading it as a JSON string instead of an
	// object is the exact bug that reached production (#385).
	paritytest.AssertLimit(t, e, "default_attributes", "maxBytes", maxDefaultAttributesBytes)
	f, ok := e.Field("default_attributes")
	if !ok || f.Check("jsonObject") == nil {
		t.Fatal("description must keep the default_attributes-must-be-an-object check (#385)")
	}
	// ...but NOT against an explicit `null`, which is how a CLEARED bag reaches
	// the wire (validateDefaultAttributes' doc comment). Without allowNull the
	// client would reject every "clear this journey's defaults" edit on the
	// device, which is worse than the server rejection this description exists
	// to pre-empt.
	if !f.Check("jsonObject").AllowNull {
		t.Fatal("description must mark default_attributes' jsonObject check allowNull: validateDefaultAttributes accepts an explicit null (#385)")
	}

	// The main-activity-type and status vocabularies stay server-owned: they
	// are extensible in code, so a frozen client copy would permanently reject
	// a value a newer server accepts.
	paritytest.AssertNoVocabulary(t, e, "main_activity_type")
	paritytest.AssertNoVocabulary(t, e, "status")

	paritytest.AssertDescribesOnlyWireFields(t, e, journeyData{})
}

func TestSharedValidationDescription_MatchesJourneyPlanItemOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeJourneyPlanItem)

	// A plan item has no mutable content of its own, so no patch.
	paritytest.AssertOps(t, e, "put", "delete")
	// Both ids are required unconditionally on the content-bearing op.
	paritytest.AssertRequiredOn(t, e, "journey_id", "put", "patch")
	paritytest.AssertRequiredOn(t, e, "apiary_id", "put", "patch")
	paritytest.AssertAbsentWhen(t, e, "journey_id", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "apiary_id", paritytest.AbsentNull)
	paritytest.AssertDescribesOnlyWireFields(t, e, journeyPlanItemData{})
}
