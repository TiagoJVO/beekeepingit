// Package api holds the todos service's HTTP surface (#50, FR-TD-1,
// FR-TEN-2, FR-HIS-1). This file (types.go) is the controlled-vocabulary
// registry for `priority` and `status` (D-20: "validated in Go, not a DB
// enum/CHECK") — much smaller than activities' per-type JSONB attribute
// registry (api/types.go there) since a todo has no per-type attributes bag
// at all: every FR-TD-1 field is a plain typed column.
package api

import "sort"

// Priorities is the known priority vocabulary (FR-TD-1). Extensible in code
// (a future priority level is a code-only append here, mirroring
// activities' typeSchemas/KnownActivityTypes convention), never a DB
// enum/CHECK (D-20).
var Priorities = []string{PriorityLow, PriorityMedium, PriorityHigh}

// Priority values (see Priorities above).
const (
	PriorityLow    = "low"
	PriorityMedium = "medium"
	PriorityHigh   = "high"
)

// Statuses is the known status vocabulary (FR-TD-1's create/complete/reopen
// lifecycle). Extensible in code, never a DB enum/CHECK (D-20).
var Statuses = []string{StatusOpen, StatusDone}

// Status values (see Statuses above). StatusOpen is the default for a newly
// created todo (D-23 doesn't touch status, only assignee_id — every todo
// starts open regardless of whether it's assigned).
const (
	StatusOpen = "open"
	StatusDone = "done"
)

// KnownPriorities returns the currently-registered priority vocabulary,
// sorted for deterministic output (used by tests and by the 422 error detail
// when `priority` itself is invalid).
func KnownPriorities() []string {
	out := append([]string(nil), Priorities...)
	sort.Strings(out)
	return out
}

// IsKnownPriority reports whether p is in the known, server-validated set.
func IsKnownPriority(p string) bool {
	return contains(Priorities, p)
}

// IsKnownStatus reports whether s is in the known, server-validated set.
func IsKnownStatus(s string) bool {
	return contains(Statuses, s)
}

func contains(vocab []string, v string) bool {
	for _, c := range vocab {
		if c == v {
			return true
		}
	}
	return false
}
