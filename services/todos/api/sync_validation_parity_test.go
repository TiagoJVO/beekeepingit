package api

import (
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation/paritytest"
)

// Binds this service's sync-op rules to the shared validation description the
// offline client re-checks queued edits against before pushing (sync.md §9,
// D-12, #584) — see services/shared/syncvalidation/paritytest for why.
func TestSharedValidationDescription_MatchesTodoOp(t *testing.T) {
	e := paritytest.Entity(t, paritytest.Load(t, 3), entityTypeTodo)

	paritytest.AssertOps(t, e, "put", "patch", "delete")
	// title/priority are required on a put only — the complete/reopen patch
	// carries just status + completed_at (#378).
	paritytest.AssertRequiredOn(t, e, "title", "put")
	paritytest.AssertRequiredOn(t, e, "priority", "put")
	paritytest.AssertLimit(t, e, "title", "maxLength", maxTitleLength)
	paritytest.AssertLimit(t, e, "description", "maxLength", maxDescriptionLength)

	// title is the one field this service trims before deciding it is missing;
	// the description has to say so per-field, since apiaries/journeys do not.
	f, ok := e.Field("title")
	if !ok || f.AbsentWhen != "blank" {
		t.Fatalf("described title absentWhen = %q, this service trims (want \"blank\")", f.AbsentWhen)
	}

	// priority/status are extensible vocabularies (D-20) — server-owned.
	paritytest.AssertNoVocabulary(t, e, "priority")
	paritytest.AssertNoVocabulary(t, e, "status")

	paritytest.AssertDescribesOnlyWireFields(t, e, todoData{})
}
