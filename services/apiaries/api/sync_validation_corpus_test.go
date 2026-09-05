package api

import (
	"encoding/json"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation/paritytest"
)

// Boundary contract tests (#585, NFR-TST-1, FR-OF-2, D-12).
//
// sync_validation_parity_test.go binds the shared DESCRIPTION to this package's
// constants; it never calls a validator, so it cannot notice a described rule
// this package quietly stopped applying, a drifted code/message/field-path
// string, or the client's evaluator reading a rule differently.
//
// This file closes that: every case in contracts/validation/sync-ops.corpus.json
// is a concrete wire op run through THIS package's real validateOp, asserted to
// report exactly the field paths, codes and messages the corpus declares. The
// same file is replayed through the client's real evaluator in
// client/test/core/validation/sync_op_corpus_test.dart, so the two independent
// implementations of one description are compared against each other rather
// than each against its own hand-written expectations.

func TestSyncValidationCorpus(t *testing.T) {
	paritytest.RunCorpus(t, 3, validateCorpusOp,
		entityTypeApiary, entityTypeApiaryCounter, entityTypeStockDeclaration)
}

// validateCorpusOp decodes one corpus op the way the sync endpoint does and runs
// it through validateOp — the very function validateBatch/applyBatch call, so
// the corpus is checked against the server's real behaviour and not a restatement
// of it. validateOp branches on entity_type, which is what lets a case carry a
// deliberately unknown entity_type and still land in validateApiaryOp.
func validateCorpusOp(t testing.TB, index int, raw json.RawMessage) []paritytest.FieldError {
	t.Helper()
	var op Op
	if err := json.Unmarshal(raw, &op); err != nil {
		t.Fatalf("decode corpus op into this service's wire shape: %v", err)
	}
	return toParityErrors(validateOp(index, op))
}

func toParityErrors(errs []problem.FieldError) []paritytest.FieldError {
	out := make([]paritytest.FieldError, 0, len(errs))
	for _, e := range errs {
		out = append(out, paritytest.FieldError{Field: e.Field, Code: e.Code, Message: e.Message})
	}
	return out
}
