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
	paritytest.RunCorpus(t, 3, validateCorpusOp, entityTypeActivity)
}

// The pre-resolved ownership the corpus documents under `ids`. Anything else —
// notably `ids.unowned` — is a cross-organization reference, which is what the
// serverOnly `not_found` cases exercise.
var (
	corpusOwnedApiaries = map[string]bool{"1b7d4c2a-3e5f-4a6b-8c9d-0e1f2a3b4c5d": true}
	corpusOwnedJourneys = map[string]bool{"2c8e5d3b-4f6a-4b7c-9d0e-1f2a3b4c5d6e": true}
)

func validateCorpusOp(t testing.TB, index int, raw json.RawMessage) []paritytest.FieldError {
	t.Helper()
	var op Op
	if err := json.Unmarshal(raw, &op); err != nil {
		t.Fatalf("decode corpus op into this service's wire shape: %v", err)
	}
	return toParityErrors(validateActivityOp(index, op, corpusOwnedApiaries, corpusOwnedJourneys))
}

func toParityErrors(errs []problem.FieldError) []paritytest.FieldError {
	out := make([]paritytest.FieldError, 0, len(errs))
	for _, e := range errs {
		out = append(out, paritytest.FieldError{Field: e.Field, Code: e.Code, Message: e.Message})
	}
	return out
}
