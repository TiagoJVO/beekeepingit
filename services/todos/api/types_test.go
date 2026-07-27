package api

import "testing"

// TestValidatePriority_AcceptsLowMediumHigh + TestValidatePriority_RejectsUnknown
// (D-20: priority is a Go-validated controlled vocabulary, not a DB
// enum/CHECK) are the pure-unit coverage for IsKnownPriority, table-driven
// per this repo's testing conventions.
func TestValidatePriority_AcceptsLowMediumHigh(t *testing.T) {
	for _, p := range []string{PriorityLow, PriorityMedium, PriorityHigh} {
		if !IsKnownPriority(p) {
			t.Errorf("IsKnownPriority(%q) = false, want true", p)
		}
	}
}

func TestValidatePriority_RejectsUnknown(t *testing.T) {
	cases := []string{"", "urgent", "LOW", "Low", "critical"}
	for _, p := range cases {
		if IsKnownPriority(p) {
			t.Errorf("IsKnownPriority(%q) = true, want false", p)
		}
	}
}

func TestValidateStatus_AcceptsOpenAndDone(t *testing.T) {
	for _, s := range []string{StatusOpen, StatusDone} {
		if !IsKnownStatus(s) {
			t.Errorf("IsKnownStatus(%q) = false, want true", s)
		}
	}
}

func TestValidateStatus_RejectsUnknown(t *testing.T) {
	cases := []string{"", "closed", "Done", "in_progress", "pending"}
	for _, s := range cases {
		if IsKnownStatus(s) {
			t.Errorf("IsKnownStatus(%q) = true, want false", s)
		}
	}
}

func TestKnownPriorities_IsSortedAndComplete(t *testing.T) {
	got := KnownPriorities()
	want := []string{"high", "low", "medium"}
	if len(got) != len(want) {
		t.Fatalf("KnownPriorities() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("KnownPriorities() = %v, want %v", got, want)
		}
	}
}
