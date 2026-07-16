package api

// Fast, pure-function unit tests for the #38 type registry (types.go) — no
// DB/Docker dependency, `go test ./api/...` completes in milliseconds.
// Table-driven, mirroring apiaries/api's own test style
// (services/apiaries/api/validate_test.go). Covers every AC in #38:
// per-type required/optional attributes (incl. the required honey_supers
// field), rejecting unknown/malformed attributes, the controlled candidate
// vocabularies (feed type, treatment type/context), and the
// conditionally-required "disease" field.

import (
	"testing"

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

func TestKnownActivityTypes(t *testing.T) {
	want := []string{TypeFeeding, TypeGeneric, TypeHarvest, TypeTreatment}
	got := KnownActivityTypes()
	if len(got) != len(want) {
		t.Fatalf("KnownActivityTypes() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("KnownActivityTypes() = %v, want %v", got, want)
		}
	}
}

func TestIsKnownActivityType(t *testing.T) {
	for _, tc := range []string{TypeHarvest, TypeFeeding, TypeTreatment, TypeGeneric} {
		if !IsKnownActivityType(tc) {
			t.Fatalf("IsKnownActivityType(%q) = false, want true", tc)
		}
	}
	if IsKnownActivityType("nucs") {
		t.Fatalf("IsKnownActivityType(%q) = true, want false", "nucs")
	}
}

func TestValidateActivity_UnknownType(t *testing.T) {
	errs := ValidateActivity("nucs", map[string]any{})
	if !hasFieldCode(errs, "type", "invalid") {
		t.Fatalf("errs = %+v, want a type/invalid error", errs)
	}
}

func TestValidateActivity_Harvest(t *testing.T) {
	tests := []struct {
		name      string
		attrs     map[string]any
		wantValid bool
		wantField string
		wantCode  string
	}{
		{
			name:      "valid: all fields",
			attrs:     map[string]any{"honey_supers": float64(4), "honey_kg": float64(12.5), "hives_involved": float64(6), "notes": "boa colheita"},
			wantValid: true,
		},
		{
			name:      "valid: only the required field",
			attrs:     map[string]any{"honey_supers": float64(0)},
			wantValid: true,
		},
		{
			name:      "missing honey_supers is rejected (#38 AC: required, primary yield metric)",
			attrs:     map[string]any{"honey_kg": float64(10)},
			wantField: "attributes.honey_supers", wantCode: "required",
		},
		{
			name:      "null honey_supers is treated as missing",
			attrs:     map[string]any{"honey_supers": nil},
			wantField: "attributes.honey_supers", wantCode: "required",
		},
		{
			name:      "non-integer honey_supers is malformed",
			attrs:     map[string]any{"honey_supers": float64(2.5)},
			wantField: "attributes.honey_supers", wantCode: "invalid",
		},
		{
			name:      "negative honey_supers is out of range",
			attrs:     map[string]any{"honey_supers": float64(-1)},
			wantField: "attributes.honey_supers", wantCode: "out_of_range",
		},
		{
			name:      "string honey_supers is malformed",
			attrs:     map[string]any{"honey_supers": "4"},
			wantField: "attributes.honey_supers", wantCode: "invalid",
		},
		{
			name:      "negative honey_kg is out of range",
			attrs:     map[string]any{"honey_supers": float64(1), "honey_kg": float64(-5)},
			wantField: "attributes.honey_kg", wantCode: "out_of_range",
		},
		{
			name:      "unknown attribute is rejected",
			attrs:     map[string]any{"honey_supers": float64(1), "colour": "amber"},
			wantField: "attributes.colour", wantCode: "invalid",
		},
		{
			name:      "notes over the length limit is rejected",
			attrs:     map[string]any{"honey_supers": float64(1), "notes": string(make([]byte, maxNotesLength+1))},
			wantField: "attributes.notes", wantCode: "too_long",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			errs := ValidateActivity(TypeHarvest, tc.attrs)
			if tc.wantValid {
				if len(errs) != 0 {
					t.Fatalf("ValidateActivity(harvest, %+v) = %+v, want no errors", tc.attrs, errs)
				}
				return
			}
			if !hasFieldCode(errs, tc.wantField, tc.wantCode) {
				t.Fatalf("ValidateActivity(harvest, %+v) = %+v, want field=%q code=%q", tc.attrs, errs, tc.wantField, tc.wantCode)
			}
		})
	}
}

func TestValidateActivity_Feeding(t *testing.T) {
	tests := []struct {
		name      string
		attrs     map[string]any
		wantValid bool
		wantField string
		wantCode  string
	}{
		{
			name:      "valid: required fields only",
			attrs:     map[string]any{"feed_type": "Xarope 1:1", "feed_amount": float64(2)},
			wantValid: true,
		},
		{
			name:      "valid: with optional hives_involved and notes",
			attrs:     map[string]any{"feed_type": "Candi", "feed_amount": float64(1.5), "hives_involved": float64(3), "notes": "n"},
			wantValid: true,
		},
		{
			name:      "missing feed_type",
			attrs:     map[string]any{"feed_amount": float64(1)},
			wantField: "attributes.feed_type", wantCode: "required",
		},
		{
			name:      "feed_type outside the candidate vocabulary",
			attrs:     map[string]any{"feed_type": "Sugar Water", "feed_amount": float64(1)},
			wantField: "attributes.feed_type", wantCode: "invalid",
		},
		{
			name:      "missing feed_amount",
			attrs:     map[string]any{"feed_type": "Pólen"},
			wantField: "attributes.feed_amount", wantCode: "required",
		},
		{
			name:      "negative feed_amount",
			attrs:     map[string]any{"feed_type": "Pólen", "feed_amount": float64(-1)},
			wantField: "attributes.feed_amount", wantCode: "out_of_range",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			errs := ValidateActivity(TypeFeeding, tc.attrs)
			if tc.wantValid {
				if len(errs) != 0 {
					t.Fatalf("ValidateActivity(feeding, %+v) = %+v, want no errors", tc.attrs, errs)
				}
				return
			}
			if !hasFieldCode(errs, tc.wantField, tc.wantCode) {
				t.Fatalf("ValidateActivity(feeding, %+v) = %+v, want field=%q code=%q", tc.attrs, errs, tc.wantField, tc.wantCode)
			}
		})
	}
}

func TestValidateActivity_Treatment(t *testing.T) {
	tests := []struct {
		name      string
		attrs     map[string]any
		wantValid bool
		wantField string
		wantCode  string
	}{
		{
			name: "valid: general/preventive, no disease needed",
			attrs: map[string]any{
				"treatment_context": TreatmentContextGeneral, "treatment_type": "Timol",
			},
			wantValid: true,
		},
		{
			name: "valid: disease_specific with disease provided",
			attrs: map[string]any{
				"treatment_context": TreatmentContextDiseaseSpecific, "treatment_type": "Apivar/amitraz", "disease": "Varroose",
			},
			wantValid: true,
		},
		{
			name: "valid: detection_only with disease provided",
			attrs: map[string]any{
				"treatment_context": TreatmentContextDetectionOnly, "treatment_type": "Outro", "disease": "Loque americana",
			},
			wantValid: true,
		},
		{
			name:      "missing treatment_context",
			attrs:     map[string]any{"treatment_type": "Timol"},
			wantField: "attributes.treatment_context", wantCode: "required",
		},
		{
			name:      "missing treatment_type",
			attrs:     map[string]any{"treatment_context": TreatmentContextGeneral},
			wantField: "attributes.treatment_type", wantCode: "required",
		},
		{
			name:      "treatment_context outside the candidate vocabulary",
			attrs:     map[string]any{"treatment_context": "unknown_context", "treatment_type": "Timol"},
			wantField: "attributes.treatment_context", wantCode: "invalid",
		},
		{
			name:      "treatment_type outside the candidate vocabulary",
			attrs:     map[string]any{"treatment_context": TreatmentContextGeneral, "treatment_type": "Honey"},
			wantField: "attributes.treatment_type", wantCode: "invalid",
		},
		{
			name: "disease_specific without disease is rejected (conditional requirement)",
			attrs: map[string]any{
				"treatment_context": TreatmentContextDiseaseSpecific, "treatment_type": "Timol",
			},
			wantField: "attributes.disease", wantCode: "required",
		},
		{
			name: "detection_only without disease is rejected (conditional requirement)",
			attrs: map[string]any{
				"treatment_context": TreatmentContextDetectionOnly, "treatment_type": "Timol",
			},
			wantField: "attributes.disease", wantCode: "required",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			errs := ValidateActivity(TypeTreatment, tc.attrs)
			if tc.wantValid {
				if len(errs) != 0 {
					t.Fatalf("ValidateActivity(treatment, %+v) = %+v, want no errors", tc.attrs, errs)
				}
				return
			}
			if !hasFieldCode(errs, tc.wantField, tc.wantCode) {
				t.Fatalf("ValidateActivity(treatment, %+v) = %+v, want field=%q code=%q", tc.attrs, errs, tc.wantField, tc.wantCode)
			}
		})
	}
}

func TestValidateActivity_Generic(t *testing.T) {
	if errs := ValidateActivity(TypeGeneric, map[string]any{}); len(errs) != 0 {
		t.Fatalf("ValidateActivity(generic, {}) = %+v, want no errors (notes is optional)", errs)
	}
	if errs := ValidateActivity(TypeGeneric, map[string]any{"notes": "checked the entrance"}); len(errs) != 0 {
		t.Fatalf("ValidateActivity(generic, {notes:...}) = %+v, want no errors", errs)
	}
	errs := ValidateActivity(TypeGeneric, map[string]any{"honey_supers": float64(1)})
	if !hasFieldCode(errs, "attributes.honey_supers", "invalid") {
		t.Fatalf("ValidateActivity(generic, {honey_supers:...}) = %+v, want attributes.honey_supers/invalid (not a generic attribute)", errs)
	}
}
