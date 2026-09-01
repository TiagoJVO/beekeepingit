package api

import (
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation/paritytest"
)

// The shared validation description (contracts/validation/, sync.md §9, D-12,
// #584) is what the offline client re-checks queued edits against BEFORE
// pushing, so a problem is caught on the device rather than coming back as a
// rejection. This service stays authoritative — but that only means anything if
// the description and this package's validate*Op actually agree.
//
// These tests bind the drift-prone half of the mirror — the caps, the bounds,
// the allowed op kinds and the put/patch required gating — to this package's own
// constants, so changing a rule here without updating the description fails the
// build instead of silently teaching the client to reject valid edits. The
// exhaustive per-rule boundary contract tests (synthesize an op violating one
// rule, assert this service reports exactly that field and code) are #585's.

func TestSharedValidationDescription_MatchesApiaryOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeApiary)

	paritytest.AssertOps(t, e, "put", "patch", "delete")
	// The #378 gating from the client's side: name is required on a put only —
	// a patch is a partial update, and demanding it of one would make the
	// client reject edits validateApiaryOp accepts.
	paritytest.AssertRequiredOn(t, e, "name", "put")
	// validateApiaryOp guards name with `*data.Name == ""`, NOT TrimSpace — so a
	// whitespace-only name is accepted here, and the client must accept it too.
	paritytest.AssertAbsentWhen(t, e, "name", paritytest.AbsentEmpty)
	paritytest.AssertAbsentWhen(t, e, "notes", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "place_label", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "hive_count", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "location_lon", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "location_lat", paritytest.AbsentNull)
	paritytest.AssertLimit(t, e, "name", "maxLength", 200)
	paritytest.AssertLimit(t, e, "notes", "maxLength", 10000)
	paritytest.AssertLimit(t, e, "place_label", "maxLength", maxPlaceLabelLength)
	paritytest.AssertLimit(t, e, "hive_count", "min", 0)
	paritytest.AssertLimit(t, e, "dgav_registration_number", "maxLength", maxDgavRegistrationNumberLength)
	paritytest.AssertAbsentWhen(t, e, "dgav_registration_number", paritytest.AbsentNull)
	paritytest.AssertRange(t, e, "location_lon", -180, 180)
	paritytest.AssertRange(t, e, "location_lat", -90, 90)
	paritytest.AssertDescribesOnlyWireFields(t, e, apiaryData{})
}

func TestSharedValidationDescription_MatchesCounterOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeApiaryCounter)

	// A counter has no independent delete (validateCounterOp).
	paritytest.AssertOps(t, e, "put", "patch")
	// The identity pair is required on BOTH op kinds — this service identifies
	// a counter by (apiary_id, counter_type), never by the client row id.
	paritytest.AssertRequiredOn(t, e, "apiary_id", "put", "patch")
	paritytest.AssertRequiredOn(t, e, "counter_type", "put", "patch")
	// value is required on a put only: a value-less patch is an idempotent
	// no-op here, not a rejection (#378).
	paritytest.AssertRequiredOn(t, e, "value", "put")
	paritytest.AssertLimit(t, e, "value", "min", 0)
	// validateCounterOp guards all three on nil alone — an empty apiary_id or
	// counter_type is "present but malformed" here, not "absent".
	paritytest.AssertAbsentWhen(t, e, "apiary_id", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "counter_type", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "value", paritytest.AbsentNull)
	paritytest.AssertNoVocabulary(t, e, "counter_type")
	paritytest.AssertDescribesOnlyWireFields(t, e, counterData{})
}

func TestSharedValidationDescription_MatchesDeclarationOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeStockDeclaration)

	// Unlike a counter, a declaration is an independent record with its own
	// lifecycle, so it DOES accept delete (validateDeclarationOp).
	paritytest.AssertOps(t, e, "put", "patch", "delete")
	// The two facts that make a declaration a declaration are required on a
	// full put only; a patch is partial (#378).
	paritytest.AssertRequiredOn(t, e, "declared_on", "put")
	paritytest.AssertRequiredOn(t, e, "total_hive_count", "put")
	paritytest.AssertLimit(t, e, "total_hive_count", "min", 0)
	paritytest.AssertLimit(t, e, "dgav_registration_number", "maxLength", maxDgavRegistrationNumberLength)
	paritytest.AssertLimit(t, e, "notes", "maxLength", maxDeclarationNotesLength)
	// validateDeclarationOp guards every field on nil alone — no "" special
	// case anywhere in it.
	paritytest.AssertAbsentWhen(t, e, "declared_on", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "total_hive_count", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "dgav_registration_number", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "notes", paritytest.AbsentNull)

	// breakdown is deliberately server-only: its shape rules (bounded array of
	// objects) don't fit the field-check vocabulary, and the client is the side
	// that builds it. Describing it as a jsonObject would be actively WRONG —
	// it is an array — and would reject every declaration.
	if _, ok := e.Field("breakdown"); ok {
		t.Fatal("description constrains breakdown; it is server-only (and is an array, not an object)")
	}

	paritytest.AssertDescribesOnlyWireFields(t, e, declarationData{})
}
