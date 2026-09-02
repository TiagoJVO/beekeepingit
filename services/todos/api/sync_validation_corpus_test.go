package api

import (
	"encoding/json"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation/paritytest"
)

// Boundary contract tests (#585, NFR-TST-1, FR-OF-2, D-12) — see the file-level
// comment in services/apiaries/api/sync_validation_corpus_test.go for what these
// add over sync_validation_parity_test.go's description-to-constants binding.

func TestSyncValidationCorpus(t *testing.T) {
	paritytest.RunCorpus(t, 3, validateCorpusOp, entityTypeTodo)
}

// The pre-resolved ownership the corpus documents under `ids`. Anything else —
// notably `ids.unowned` — is a cross-organization reference, which is what the
// serverOnly `not_found` cases exercise.
var (
	corpusOwnedAssignees = map[string]bool{"33333333-3333-3333-3333-333333333333": true}
	corpusOwnedApiaries  = map[string]bool{"11111111-1111-1111-1111-111111111111": true}
)

func validateCorpusOp(t testing.TB, index int, raw json.RawMessage) []paritytest.FieldError {
	t.Helper()
	var op Op
	if err := json.Unmarshal(raw, &op); err != nil {
		t.Fatalf("decode corpus op into this service's wire shape: %v", err)
	}
	return toParityErrors(validateTodoOp(index, op, corpusOwnedAssignees, corpusOwnedApiaries))
}

func toParityErrors(errs []problem.FieldError) []paritytest.FieldError {
	out := make([]paritytest.FieldError, 0, len(errs))
	for _, e := range errs {
		out = append(out, paritytest.FieldError{Field: e.Field, Code: e.Code, Message: e.Message})
	}
	return out
}
