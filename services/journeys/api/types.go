// Package api holds the journeys service's HTTP surface (#45, EPIC-04 M4,
// FR-JO-4, FR-TEN-2, D-21). This file (types.go) is the small type registry
// this service owns directly: the known main-activity-type vocabulary a
// journey's `main_activity_type` is validated against, and the known
// journey `status` set (D-21: "open"/"closed").
//
// main-activity-type vocabulary: journeys does NOT import
// services/activities' Go module to get this list — a service only ever
// depends on another service's data by ID (service-decomposition.md §4 rule
// 2: "cross-context references are by ID, not FK"), never by importing its
// code, and the two are separate Go modules anyway (only linked via the
// repo-root go.work for local builds). Instead this is a HAND-KEPT MIRROR of
// services/activities/api/types.go's own registry (TypeHarvest/TypeFeeding/
// TypeTreatment/TypeGeneric) — the exact same mirroring convention the
// client already follows for the very same vocabulary
// (client/lib/features/activities/activity_types.dart mirrors
// services/activities/api/types.go; this file is a second, server-side
// mirror of the identical set). Extending the activity-type vocabulary is
// therefore a code-only append in THREE places kept in lockstep: activities'
// own registry, this file, and the client's activity_types.dart — exactly
// the same "extensible enums" convention (data-model.md §2) already used
// elsewhere, just mirrored one hop further.
package api

import (
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// The known main-activity-type vocabulary (D-21, FR-JO-4: "one main activity
// type per journey") — mirrors services/activities/api/types.go's own
// TypeHarvest/TypeFeeding/TypeTreatment/TypeGeneric constants exactly (see
// this file's package doc for why this is a hand-kept mirror, not an
// import).
const (
	ActivityTypeHarvest   = "harvest"
	ActivityTypeFeeding   = "feeding"
	ActivityTypeTreatment = "treatment"
	ActivityTypeGeneric   = "generic"
)

// knownMainActivityTypes is the validated set, in the same picker order the
// client's activity_types.dart uses (attribute-carrying types first, generic
// last as the catch-all).
var knownMainActivityTypes = []string{
	ActivityTypeHarvest,
	ActivityTypeFeeding,
	ActivityTypeTreatment,
	ActivityTypeGeneric,
}

// IsKnownMainActivityType reports whether t is in the known, server-validated
// set.
func IsKnownMainActivityType(t string) bool {
	for _, k := range knownMainActivityTypes {
		if k == t {
			return true
		}
	}
	return false
}

// KnownMainActivityTypes returns the currently-registered main activity
// types, for error messages and tests.
func KnownMainActivityTypes() []string {
	out := make([]string, len(knownMainActivityTypes))
	copy(out, knownMainActivityTypes)
	return out
}

// Journey status (D-21): "open" journeys are selectable and auto-matched by
// default in the activity-form picker (#46); "closed" journeys are hidden by
// default there, but remain selectable (with a confirm-to-proceed warning).
// Extensible-enum-as-text convention (data-model.md §2), not a fixed set of
// two forever — kept as a `[]string` + validator, not a Go `bool`, so a
// future status is a code-only append, mirroring every other "extensible
// enum" in this codebase.
const (
	StatusOpen   = "open"
	StatusClosed = "closed"
)

var knownStatuses = []string{StatusOpen, StatusClosed}

// IsKnownStatus reports whether s is a known journey status.
func IsKnownStatus(s string) bool {
	for _, k := range knownStatuses {
		if k == s {
			return true
		}
	}
	return false
}

// maxNameLength bounds a journey's name — generous for a short descriptive
// label (e.g. "Colheita de Primavera 2026"), matching apiaries'/activities'
// own short-label caps.
const maxNameLength = 200

// maxApiaryIDsPerJourney bounds how many apiaries a single journey's plan may
// name in one request/op — a defensive cap (mirrors sync.go's maxBatchOps
// rationale: bounds worst-case transaction size and per-request cross-service
// ownership-verification cost), generous for any real organization's apiary
// count.
const maxApiaryIDsPerJourney = 500

// validateJourneyFields validates the shared create/update field set — name,
// main_activity_type, and the apiary_ids list's SHAPE (well-formed UUIDs, no
// duplicates, within the size cap) — returning the parsed apiary ids as
// uuid.UUIDs in their submitted order. It does NOT verify apiary_id
// ownership (a cross-service HTTP call, done by the caller via
// ApiaryVerifier) or journey_id existence (a DB read) — purely wire-shape
// validation, mirroring activities' validateActivityCreate/
// validateActivityUpdate split between shape checks here and the ownership
// check in write.go itself.
func validateJourneyFields(name, mainActivityType string, apiaryIDs []string) (parsed []uuid.UUID, errs []problem.FieldError) {
	switch {
	case strings.TrimSpace(name) == "":
		errs = append(errs, problem.FieldError{Field: "name", Code: "required", Message: "name must not be empty"})
	case len(name) > maxNameLength:
		errs = append(errs, problem.FieldError{Field: "name", Code: "too_long", Message: fmt.Sprintf("name must be at most %d characters", maxNameLength)})
	}

	if !IsKnownMainActivityType(mainActivityType) {
		errs = append(errs, problem.FieldError{
			Field:   "main_activity_type",
			Code:    "invalid",
			Message: fmt.Sprintf("main_activity_type must be one of the known activity types: %v", KnownMainActivityTypes()),
		})
	}

	if len(apiaryIDs) > maxApiaryIDsPerJourney {
		errs = append(errs, problem.FieldError{
			Field:   "apiary_ids",
			Code:    "too_many",
			Message: fmt.Sprintf("apiary_ids must contain at most %d entries (got %d)", maxApiaryIDsPerJourney, len(apiaryIDs)),
		})
		return nil, errs
	}

	seen := make(map[string]bool, len(apiaryIDs))
	for i, raw := range apiaryIDs {
		id, err := uuid.Parse(raw)
		if err != nil {
			errs = append(errs, problem.FieldError{
				Field:   fmt.Sprintf("apiary_ids[%d]", i),
				Code:    "invalid",
				Message: "apiary_ids entries must be UUIDs",
			})
			continue
		}
		if seen[id.String()] {
			errs = append(errs, problem.FieldError{
				Field:   fmt.Sprintf("apiary_ids[%d]", i),
				Code:    "duplicate",
				Message: "apiary_ids must not repeat the same apiary",
			})
			continue
		}
		seen[id.String()] = true
		parsed = append(parsed, id)
	}
	return parsed, errs
}
