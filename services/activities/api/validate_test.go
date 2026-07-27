package api

// Fast, pure-function unit tests for validateRequestErrors (validate.go) —
// the wire-level layer above ValidateActivity (types_test.go covers the
// per-type schema itself). No DB/Docker dependency.

import (
	"encoding/json"
	"testing"
)

func TestValidateRequestErrors_Valid(t *testing.T) {
	body := validateRequestBody{
		Type:       TypeHarvest,
		OccurredAt: "2026-07-16",
		Attributes: json.RawMessage(`{"honey_supers": 3, "honey_kg": 9.5}`),
	}
	if errs := validateRequestErrors(body); len(errs) != 0 {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want no errors", body, errs)
	}
}

func TestValidateRequestErrors_ValidWithoutAttributes(t *testing.T) {
	body := validateRequestBody{Type: TypeGeneric, OccurredAt: "2026-07-16"}
	if errs := validateRequestErrors(body); len(errs) != 0 {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want no errors (generic has no required attributes)", body, errs)
	}
}

func TestValidateRequestErrors_MissingOccurredAt(t *testing.T) {
	body := validateRequestBody{Type: TypeGeneric}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "occurred_at", "required") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want occurred_at/required", body, errs)
	}
}

func TestValidateRequestErrors_MalformedOccurredAt(t *testing.T) {
	body := validateRequestBody{Type: TypeGeneric, OccurredAt: "16-07-2026"}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "occurred_at", "invalid") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want occurred_at/invalid", body, errs)
	}
}

func TestValidateRequestErrors_MissingType(t *testing.T) {
	body := validateRequestBody{OccurredAt: "2026-07-16"}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "type", "required") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want type/required", body, errs)
	}
}

func TestValidateRequestErrors_UnknownType(t *testing.T) {
	body := validateRequestBody{Type: "nucs", OccurredAt: "2026-07-16"}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "type", "invalid") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want type/invalid", body, errs)
	}
}

func TestValidateRequestErrors_MalformedAttributesJSON(t *testing.T) {
	body := validateRequestBody{Type: TypeGeneric, OccurredAt: "2026-07-16", Attributes: json.RawMessage(`not json`)}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "attributes", "invalid") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want attributes/invalid", body, errs)
	}
}

func TestValidateRequestErrors_NullAttributesRejected(t *testing.T) {
	// The literal JSON `null` for attributes must NOT silently skip per-type
	// validation: json.Unmarshal sets a map target to nil with err == nil for
	// `null`, so a required-field type like harvest would otherwise return
	// valid with no attributes at all. Regression for the #38 review HIGH
	// finding (validate.go attrsOK tracking).
	body := validateRequestBody{
		Type: TypeHarvest, OccurredAt: "2026-07-16",
		Attributes: json.RawMessage(`null`),
	}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "attributes", "invalid") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want attributes/invalid", body, errs)
	}
}

func TestValidateRequestErrors_UnknownAndMissingAttributesCombine(t *testing.T) {
	// Harvest missing its required honey_supers AND carrying an unrecognized
	// key — both violations must surface together (#38 AC: reject unknown OR
	// malformed attributes, not just the first one found).
	body := validateRequestBody{
		Type: TypeHarvest, OccurredAt: "2026-07-16",
		Attributes: json.RawMessage(`{"colour": "amber"}`),
	}
	errs := validateRequestErrors(body)
	if !hasFieldCode(errs, "attributes.honey_supers", "required") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want attributes.honey_supers/required", body, errs)
	}
	if !hasFieldCode(errs, "attributes.colour", "invalid") {
		t.Fatalf("validateRequestErrors(%+v) = %+v, want attributes.colour/invalid", body, errs)
	}
}
