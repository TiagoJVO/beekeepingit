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

	// title is the one field in the whole description this service TRIMS before
	// deciding it is missing; the four optional strings below are guarded with
	// `!= "" `, so a cleared field is absent rather than malformed; description
	// and priority/status are guarded on nil alone. Getting any of these wrong
	// makes the client reject an edit this service accepts.
	paritytest.AssertAbsentWhen(t, e, "title", paritytest.AbsentBlank)
	paritytest.AssertAbsentWhen(t, e, "due_date", paritytest.AbsentEmpty)
	paritytest.AssertAbsentWhen(t, e, "completed_at", paritytest.AbsentEmpty)
	paritytest.AssertAbsentWhen(t, e, "assignee_id", paritytest.AbsentEmpty)
	paritytest.AssertAbsentWhen(t, e, "apiary_id", paritytest.AbsentEmpty)
	paritytest.AssertAbsentWhen(t, e, "description", paritytest.AbsentNull)
	paritytest.AssertAbsentWhen(t, e, "priority", paritytest.AbsentNull)

	// priority/status are extensible vocabularies (D-20) — server-owned.
	paritytest.AssertNoVocabulary(t, e, "priority")
	paritytest.AssertNoVocabulary(t, e, "status")

	paritytest.AssertDescribesOnlyWireFields(t, e, todoData{})
}
