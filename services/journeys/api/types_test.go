package api

// Fast, pure-function unit tests for the #45 journeys type registry
// (types.go) — no DB/Docker dependency, `go test ./api/...` completes in
// milliseconds. Table-driven, mirroring activities/api's own test style
// (services/activities/api/types_test.go).

import (
	"testing"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

func hasFieldCode(errs []problem.FieldError, field, code string) bool {
	for _, e := range errs {
		if e.Field == field && e.Code == code {
			return true
		}
	}
	return false
}

func TestKnownMainActivityTypes(t *testing.T) {
	got := KnownMainActivityTypes()
	want := []string{ActivityTypeHarvest, ActivityTypeFeeding, ActivityTypeTreatment, ActivityTypeGeneric}
	if len(got) != len(want) {
		t.Fatalf("KnownMainActivityTypes() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("KnownMainActivityTypes() = %v, want %v", got, want)
		}
	}
}

func TestIsKnownMainActivityType(t *testing.T) {
	for _, tc := range []string{ActivityTypeHarvest, ActivityTypeFeeding, ActivityTypeTreatment, ActivityTypeGeneric} {
		if !IsKnownMainActivityType(tc) {
			t.Fatalf("IsKnownMainActivityType(%q) = false, want true", tc)
		}
	}
	if IsKnownMainActivityType("nucs") {
		t.Fatalf("IsKnownMainActivityType(%q) = true, want false", "nucs")
	}
}

func TestIsKnownStatus(t *testing.T) {
	if !IsKnownStatus(StatusOpen) || !IsKnownStatus(StatusClosed) {
		t.Fatalf("IsKnownStatus(open/closed) = false, want true")
	}
	if IsKnownStatus("archived") {
		t.Fatalf("IsKnownStatus(%q) = true, want false", "archived")
	}
}

func TestValidateJourneyFields_Valid(t *testing.T) {
	apiaryA, apiaryB := uuid.New().String(), uuid.New().String()
	parsed, errs := validateJourneyFields("Colheita de Primavera", ActivityTypeHarvest, []string{apiaryA, apiaryB})
	if len(errs) != 0 {
		t.Fatalf("validateJourneyFields = %+v, want no errors", errs)
	}
	if len(parsed) != 2 {
		t.Fatalf("parsed apiary ids = %v, want 2", parsed)
	}
}

func TestValidateJourneyFields_EmptyApiaryIDsIsValid(t *testing.T) {
	// FR-JO-4 doesn't require at least one apiary to plan a journey around —
	// a journey can be created and apiaries added to its plan later via edit.
	_, errs := validateJourneyFields("Journey", ActivityTypeGeneric, nil)
	if len(errs) != 0 {
		t.Fatalf("validateJourneyFields with no apiary_ids = %+v, want no errors", errs)
	}
}

func TestValidateJourneyFields_RejectsEmptyName(t *testing.T) {
	_, errs := validateJourneyFields("   ", ActivityTypeHarvest, nil)
	if !hasFieldCode(errs, "name", "required") {
		t.Fatalf("errs = %+v, want name/required", errs)
	}
}

func TestValidateJourneyFields_RejectsTooLongName(t *testing.T) {
	longName := make([]byte, maxNameLength+1)
	for i := range longName {
		longName[i] = 'a'
	}
	_, errs := validateJourneyFields(string(longName), ActivityTypeHarvest, nil)
	if !hasFieldCode(errs, "name", "too_long") {
		t.Fatalf("errs = %+v, want name/too_long", errs)
	}
}

func TestValidateJourneyFields_RejectsUnknownMainActivityType(t *testing.T) {
	_, errs := validateJourneyFields("Journey", "nucs", nil)
	if !hasFieldCode(errs, "main_activity_type", "invalid") {
		t.Fatalf("errs = %+v, want main_activity_type/invalid", errs)
	}
}

func TestValidateJourneyFields_RejectsMalformedApiaryID(t *testing.T) {
	_, errs := validateJourneyFields("Journey", ActivityTypeHarvest, []string{"not-a-uuid"})
	if !hasFieldCode(errs, "apiary_ids[0]", "invalid") {
		t.Fatalf("errs = %+v, want apiary_ids[0]/invalid", errs)
	}
}

func TestValidateJourneyFields_RejectsDuplicateApiaryID(t *testing.T) {
	id := uuid.New().String()
	_, errs := validateJourneyFields("Journey", ActivityTypeHarvest, []string{id, id})
	if !hasFieldCode(errs, "apiary_ids[1]", "duplicate") {
		t.Fatalf("errs = %+v, want apiary_ids[1]/duplicate", errs)
	}
}

func TestValidateJourneyFields_RejectsTooManyApiaryIDs(t *testing.T) {
	ids := make([]string, maxApiaryIDsPerJourney+1)
	for i := range ids {
		ids[i] = uuid.New().String()
	}
	_, errs := validateJourneyFields("Journey", ActivityTypeHarvest, ids)
	if !hasFieldCode(errs, "apiary_ids", "too_many") {
		t.Fatalf("errs = %+v, want apiary_ids/too_many", errs)
	}
}
