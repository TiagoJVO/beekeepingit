// Package api holds the activities service's per-type attribute model and
// server-side validation (#38, FR-AC-1, D-2, D-19). This file (types.go) is
// the type registry: the extensible set of known activity types and each
// type's own attribute schema, validated against the JSONB `attributes` bag
// (store/migrations/00001_create_activities.sql) rather than a DB
// enum/CHECK — mirroring the data-model.md §2 "extensible enums" convention
// apiaries' counter_type already uses (services/apiaries/api/counters.go).
//
// Adding a future activity type (or a future attribute on an existing type)
// is a CODE-ONLY change: append a new entry to typeSchemas (and, for a new
// type, a new exported Type* constant) — no migration to
// activities.activities or its `attributes` JSONB column (FR-AC-1 AC: "new
// types = code-only"). The client mirrors this same set
// (client/lib/features/activities/activity_types.dart), matching how
// apiaries' counter_types.dart mirrors counters.go's knownCounterTypes.
package api

import (
	"fmt"
	"math"
	"sort"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// The four initial activity types (FR-AC-1). TypeGeneric is the fallback
// type for anything that doesn't fit the other three (date + notes only).
const (
	TypeHarvest   = "harvest"
	TypeFeeding   = "feeding"
	TypeTreatment = "treatment"
	TypeGeneric   = "generic"
)

// Controlled candidate vocabularies (FR-AC-1 AC: "extensible, not a closed
// enum"). Like activity types themselves, these are validated in Go against
// a known set — not a DB enum/CHECK — so extending a vocabulary (e.g. a new
// feed product) is a code-only append here (and in the client mirror), never
// a migration. Exported so the client-mirroring doc comments above and any
// future admin/reporting code can reference the canonical Go set directly in
// tests.
var (
	// FeedTypes is the known feed-type vocabulary (Alimentação, prototype.md).
	FeedTypes = []string{"Xarope 1:1", "Xarope 2:1", "Candi", "Pólen"}

	// TreatmentTypes is the known treatment-product vocabulary (Tratamento,
	// prototype.md).
	TreatmentTypes = []string{"Apivar/amitraz", "Ácido oxálico", "Timol", "Outro"}

	// TreatmentContexts is the known treatment-context vocabulary (FR-AC-1,
	// confirmed 2026-07-16 as committed v1 scope, D-19's "future-relevant
	// data point" on Treatment activities): whether a treatment is
	// general/preventive (no disease tied to it), tied to a specific named
	// disease/condition, or a detection-only report (a disease observed, no
	// treatment applied yet).
	TreatmentContexts = []string{
		TreatmentContextGeneral,
		TreatmentContextDiseaseSpecific,
		TreatmentContextDetectionOnly,
	}

	// DiseaseConditions is the known disease/condition candidate vocabulary
	// for Treatment activities' "disease" attribute (#291, FR-AC-1, D-19),
	// sourced from DGAV's mandatory-notification bee-disease list (DDO, DL
	// 203/2005 Annex II) as enumerated in
	// docs/research/regulatory-pt-eu-beekeeping.md §B.6: Acariose
	// (Acarapisose), Tropilaelaps spp. infestation, Aethina tumida (small
	// hive beetle) infestation, American foulbrood (loque americana),
	// European foulbrood (loque europeia), nosemosis, and varroosis — the
	// current national/EU DDO list, not the requirements folder (which only
	// commits to "a DGAV-DDO-informed list", D-19). "Outro" is a catch-all
	// so a diagnosis outside this list can still be recorded (with detail in
	// the free-text notes field), mirroring TreatmentTypes' own "Outro"
	// entry. Extensible in code, not a closed DB enum — see the package doc.
	// This initial set is sourced directly from the research note and has
	// not been separately confirmed by product; see this PR's description.
	DiseaseConditions = []string{
		"Varroose",
		"Loque americana",
		"Loque europeia",
		"Nosemose",
		"Acariose",
		"Aethina tumida (pequeno besouro da colmeia)",
		"Tropilaelaps spp.",
		"Outro",
	}
)

// TreatmentContext values (see TreatmentContexts above).
const (
	TreatmentContextGeneral         = "general_preventive"
	TreatmentContextDiseaseSpecific = "disease_specific"
	TreatmentContextDetectionOnly   = "detection_only"
)

// Attribute value kinds ValidateActivity checks a decoded JSON value against.
type attrKind int

const (
	kindString attrKind = iota
	kindNumber
	kindInteger
)

// attrSpec describes one attribute key within a type's schema: whether it's
// required, its value kind, and any extra constraints (candidate vocabulary,
// numeric bounds, string length, conditional requirement).
type attrSpec struct {
	key      string
	required bool
	kind     attrKind

	// vocab, when non-nil, restricts a string attribute to this candidate
	// vocabulary (FR-AC-1 AC) — extensible in code, not a closed DB enum.
	vocab []string

	// min bounds a number/integer attribute (inclusive). Nil means
	// unbounded below.
	min *float64

	// maxLen bounds a string attribute's length. Zero means unbounded.
	maxLen int

	// requiredIf, when non-nil, makes this attribute conditionally required
	// even when required is false — evaluated against the OTHER attributes
	// already present in the payload (e.g. Treatment's "disease" field is
	// required only when treatment_context is disease_specific or
	// detection_only).
	requiredIf func(attrs map[string]any) bool
}

func floatPtr(v float64) *float64 { return &v }

// typeSchemas is the extensible type registry (see package doc). Every
// spec's "notes" entry is optional and shared shape across all four types
// (FR-AC-1: every type carries free-text notes) — kept per-type rather than
// factored out so each type's schema is a single, self-contained slice.
var typeSchemas = map[string][]attrSpec{
	// Honey harvest (Cresta, prototype.md): date lives on the top-level
	// occurred_at column, not here. honey_supers ("alças") is the primary
	// yield metric and REQUIRED (FR-AC-1, confirmed 2026-07-16 as committed
	// v1 scope, no longer provisional) — more reliably measured in the
	// field than the kg amount, which stays optional. lot_batch (#292,
	// FR-AC-1, D-19) is an OPTIONAL free-text lot/batch identifier captured
	// at harvest time for future traceability (Reg (EC) 178/2002 Art. 18,
	// Reg (EU) 931/2011, Dir 2011/91/EU, Dir 2001/110/EC as amended by Dir
	// (EU) 2024/1438) — capture-side only here; surfacing it in exports is
	// a separate story (EPIC-09-NEW-C) blocked by #292, not this schema.
	TypeHarvest: {
		{key: "honey_supers", required: true, kind: kindInteger, min: floatPtr(0)},
		{key: "honey_kg", kind: kindNumber, min: floatPtr(0)},
		{key: "hives_involved", kind: kindInteger, min: floatPtr(0)},
		{key: "lot_batch", kind: kindString, maxLen: maxLotBatchLength},
		{key: "notes", kind: kindString, maxLen: maxNotesLength},
	},
	// Feeding (Alimentação, prototype.md): feed_type + feed_amount are both
	// required — an "empty" feeding record isn't a meaningful activity.
	// hives_involved is the optional hives-affected count FR-AC-1 allows for
	// feeding (distinct from the apiary's current-state hive counter, D-2).
	TypeFeeding: {
		{key: "feed_type", required: true, kind: kindString, vocab: FeedTypes},
		{key: "feed_amount", required: true, kind: kindNumber, min: floatPtr(0)},
		{key: "hives_involved", kind: kindInteger, min: floatPtr(0)},
		{key: "notes", kind: kindString, maxLen: maxNotesLength},
	},
	// Treatment (Tratamento, prototype.md): treatment_context is always
	// required. "treatment_type" is required UNLESS treatment_context is
	// detection_only (#291 AC: "a detection can be logged with no treatment
	// attached yet" — the disease field is not contingent on a treatment
	// being applied in the same activity). "disease" is conditionally
	// required — only when treatment_context ties the treatment to a
	// specific disease/condition or is a detection-only report (FR-AC-1) —
	// and is validated against DiseaseConditions, the DGAV-DDO-informed
	// candidate vocabulary (D-19, docs/research/regulatory-pt-eu-beekeeping.md
	// §B.6).
	TypeTreatment: {
		{key: "treatment_context", required: true, kind: kindString, vocab: TreatmentContexts},
		{
			key: "treatment_type", kind: kindString, vocab: TreatmentTypes,
			requiredIf: func(attrs map[string]any) bool {
				ctx, _ := attrs["treatment_context"].(string)
				return ctx != TreatmentContextDetectionOnly
			},
		},
		{
			key: "disease", kind: kindString, vocab: DiseaseConditions,
			requiredIf: func(attrs map[string]any) bool {
				ctx, _ := attrs["treatment_context"].(string)
				return ctx == TreatmentContextDiseaseSpecific || ctx == TreatmentContextDetectionOnly
			},
		},
		{key: "hives_involved", kind: kindInteger, min: floatPtr(0)},
		{key: "notes", kind: kindString, maxLen: maxNotesLength},
	},
	// Generic (FR-AC-1): date (top-level occurred_at) + notes only.
	TypeGeneric: {
		{key: "notes", kind: kindString, maxLen: maxNotesLength},
	},
}

const maxNotesLength = 10000

// maxLotBatchLength bounds Honey harvest's optional lot_batch identifier
// (#292, FR-AC-1, D-19) — generous for a lot/batch code (e.g. a
// date-and-location scheme like "2026-07-Melargil-A1") without allowing it
// to become a second notes field.
const maxLotBatchLength = 100

// KnownActivityTypes returns the currently-registered activity types, sorted
// for deterministic output (used by tests and by the 400/422 error detail
// when `type` itself is invalid).
func KnownActivityTypes() []string {
	out := make([]string, 0, len(typeSchemas))
	for t := range typeSchemas {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}

// IsKnownActivityType reports whether t is in the known, server-validated
// set (mirrors apiaries' isKnownCounterType).
func IsKnownActivityType(t string) bool {
	_, ok := typeSchemas[t]
	return ok
}

// ValidateActivity validates attrs (already JSON-decoded, so JSON numbers
// arrive as float64 per encoding/json's default unmarshal-into-any
// behavior) against activityType's registered schema. It returns one
// problem.FieldError per violation — unknown activity type, an attribute key
// not part of that type's schema ("reject unknown ... attributes", FR-AC-1
// AC), a missing required attribute (including a conditionally-required
// one), or a malformed value (wrong kind, non-integer where an integer is
// required, below the numeric minimum, outside the candidate vocabulary, or
// over the max string length) — a nil/empty result means attrs is valid for
// activityType. Field paths are prefixed with "attributes." so callers can
// combine them with their own field-error prefixing convention (matching
// apiaries' sync.go prefix pattern), except the activity-type error itself,
// which uses the bare "type" field.
func ValidateActivity(activityType string, attrs map[string]any) []problem.FieldError {
	specs, ok := typeSchemas[activityType]
	if !ok {
		return []problem.FieldError{{
			Field:   "type",
			Code:    "invalid",
			Message: fmt.Sprintf("type must be one of the known activity types: %v", KnownActivityTypes()),
		}}
	}

	known := make(map[string]attrSpec, len(specs))
	for _, s := range specs {
		known[s.key] = s
	}

	var errs []problem.FieldError

	// Reject unknown attribute keys (FR-AC-1 AC).
	for k := range attrs {
		if _, ok := known[k]; !ok {
			errs = append(errs, problem.FieldError{
				Field:   "attributes." + k,
				Code:    "invalid",
				Message: fmt.Sprintf("%q is not a valid attribute for activity type %q", k, activityType),
			})
		}
	}

	for _, s := range specs {
		errs = append(errs, validateAttr(s, activityType, attrs)...)
	}

	sort.Slice(errs, func(i, j int) bool { return errs[i].Field < errs[j].Field })
	return errs
}

func validateAttr(s attrSpec, activityType string, attrs map[string]any) []problem.FieldError {
	field := "attributes." + s.key
	v, present := attrs[s.key]

	required := s.required || (s.requiredIf != nil && s.requiredIf(attrs))
	if !present || v == nil {
		if required {
			return []problem.FieldError{{
				Field:   field,
				Code:    "required",
				Message: fmt.Sprintf("%q is required for activity type %q", s.key, activityType),
			}}
		}
		return nil
	}

	switch s.kind {
	case kindString:
		str, ok := v.(string)
		if !ok {
			return []problem.FieldError{{Field: field, Code: "invalid", Message: fmt.Sprintf("%q must be a string", s.key)}}
		}
		if s.vocab != nil && !contains(s.vocab, str) {
			return []problem.FieldError{{
				Field:   field,
				Code:    "invalid",
				Message: fmt.Sprintf("%q must be one of %v", s.key, s.vocab),
			}}
		}
		if s.maxLen > 0 && len(str) > s.maxLen {
			return []problem.FieldError{{
				Field:   field,
				Code:    "too_long",
				Message: fmt.Sprintf("%q must be at most %d characters", s.key, s.maxLen),
			}}
		}
	case kindNumber, kindInteger:
		num, ok := v.(float64)
		if !ok {
			return []problem.FieldError{{Field: field, Code: "invalid", Message: fmt.Sprintf("%q must be a number", s.key)}}
		}
		if s.kind == kindInteger && num != math.Trunc(num) {
			return []problem.FieldError{{Field: field, Code: "invalid", Message: fmt.Sprintf("%q must be an integer", s.key)}}
		}
		if s.min != nil && num < *s.min {
			return []problem.FieldError{{
				Field:   field,
				Code:    "out_of_range",
				Message: fmt.Sprintf("%q must be >= %v", s.key, *s.min),
			}}
		}
	}
	return nil
}

func contains(vocab []string, v string) bool {
	for _, c := range vocab {
		if c == v {
			return true
		}
	}
	return false
}
