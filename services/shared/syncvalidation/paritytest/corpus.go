package paritytest

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation"
)

// FieldError is the shape an owning service reports a validation failure in —
// structurally `problem.FieldError`, restated here so `services/shared` stays
// free of a dependency on `services/servicetemplate` (a separate module). Each
// service's corpus test converts its own `[]problem.FieldError` in three lines.
type FieldError struct {
	Field   string
	Code    string
	Message string
}

// Validate runs ONE corpus op through the owning service's real validator and
// returns exactly what it reported. `op` is the expanded, compact wire op —
// unmarshal it into that package's own `Op` and call `validate*Op(index, op)`
// with whatever server-side context (ownership maps) the signature needs; the
// harness supplies the same index it expects to see in the reported field paths.
//
// The point of taking a closure rather than a validator name is that the harness
// must call the SERVICE'S OWN function: a corpus that re-implemented the rules
// would only prove itself right.
type Validate func(t testing.TB, index int, op json.RawMessage) []FieldError

// RunCorpus runs every case of the shared boundary-contract corpus
// (contracts/validation/sync-ops.corpus.json, #585) that belongs to
// entityTypes through validate, and asserts the service reported exactly the
// case's expect ∪ serverOnly — same field paths, same codes, same messages.
//
// depth is the package's distance below the repository root
// (services/<svc>/api is 3).
//
// The corresponding client-side assertion (expect alone — the client must NOT
// report a serverOnly rule) lives in
// client/test/core/validation/sync_op_corpus_test.dart and reads the same file.
// That is the whole design: one corpus, two real evaluators, so the two cannot
// drift apart without one of them failing.
func RunCorpus(t *testing.T, depth int, validate Validate, entityTypes ...string) {
	t.Helper()

	corpus, err := syncvalidation.LoadCorpus(depth)
	if err != nil {
		t.Fatalf("load shared validation corpus: %v", err)
	}
	cases := corpus.For(entityTypes...)
	if len(cases) == 0 {
		t.Fatalf("%s carries no cases for %v — this service would be asserting nothing",
			syncvalidation.CorpusRepoRelativePath, entityTypes)
	}

	for i, kase := range cases {
		// Every case runs at a different, non-zero op index so a validator that
		// hardcoded ops[0] (or dropped the prefix altogether) fails here rather
		// than shipping field paths the client's needs-fix UI cannot match.
		index := i + 1
		t.Run(kase.Name, func(t *testing.T) {
			expanded, err := syncvalidation.ExpandCorpusOp(kase.Op)
			if err != nil {
				t.Fatalf("case %q: %v", kase.Name, err)
			}
			got := stripOpPrefix(t, index, validate(t, index, expanded))
			assertOutcomes(t, kase, got)
		})
	}
}

var opPrefixPattern = regexp.MustCompile(`^ops\[(\d+)\]\.`)

// stripOpPrefix turns the server's batch-absolute `ops[i].data.name` back into
// the corpus's op-relative `data.name`, failing if the index is not the one the
// op was validated at — the prefix is part of the contract the client's
// rejection parser depends on (powersync_connector.dart's RejectedFieldError),
// so a wrong index is a real defect, not a formatting detail.
func stripOpPrefix(t *testing.T, index int, errs []FieldError) []FieldError {
	t.Helper()
	out := make([]FieldError, 0, len(errs))
	for _, e := range errs {
		match := opPrefixPattern.FindStringSubmatch(e.Field)
		if match == nil {
			t.Fatalf("this service reported field %q, which does not start with the ops[i]. prefix "+
				"the sync contract requires (docs/architecture/sync.md §6.2)", e.Field)
		}
		if match[1] != fmt.Sprint(index) {
			t.Fatalf("this service reported field %q for the op it was handed at index %d — "+
				"the op index is not being threaded through", e.Field, index)
		}
		e.Field = strings.TrimPrefix(e.Field, match[0])
		out = append(out, e)
	}
	return out
}

// assertOutcomes compares what the service reported with what the case declares,
// and on a mismatch prints both sides in full plus the two-way difference, so
// the diverging rule and each side's behaviour are readable straight off the CI
// log without re-running anything locally.
func assertOutcomes(t *testing.T, kase syncvalidation.CorpusCase, got []FieldError) {
	t.Helper()

	want := kase.ServerExpectation()
	remaining := append([]FieldError(nil), got...)
	var missing []syncvalidation.CorpusOutcome

	// Exact triples are matched first, so a message-less serverOnly entry can
	// never absorb an outcome an exact expectation was waiting for.
	for _, exact := range []bool{true, false} {
		for _, w := range want {
			if (w.Message != "") != exact {
				continue
			}
			idx := indexOf(remaining, w)
			if idx < 0 {
				missing = append(missing, w)
				continue
			}
			remaining = append(remaining[:idx], remaining[idx+1:]...)
		}
	}

	if len(missing) == 0 && len(remaining) == 0 {
		return
	}

	var b strings.Builder
	fmt.Fprintf(&b, "\nVALIDATION PARITY BROKEN — case %q (%s)\n", kase.Name, syncvalidation.CorpusRepoRelativePath)
	if kase.Why != "" {
		fmt.Fprintf(&b, "  what the case is for: %s\n", kase.Why)
	}
	writeOutcomes(&b, "  the corpus says BOTH sides must report", kase.Expect)
	writeOutcomes(&b, "  the corpus says ONLY this server reports", kase.ServerOnly)
	writeFieldErrors(&b, "  this server actually reported", got)
	writeOutcomes(&b, "  MISSING — declared, but this server did not report it", missing)
	writeFieldErrors(&b, "  UNEXPECTED — this server reported it, but nothing declares it", remaining)
	b.WriteString("  Fix the rule in this service, or update the corpus AND the shared description " +
		"(contracts/validation/sync-ops.validation.json) together — the client runs these same cases in " +
		"client/test/core/validation/sync_op_corpus_test.dart, so a change to one side alone will fail there instead.\n")
	t.Fatal(b.String())
}

func indexOf(errs []FieldError, want syncvalidation.CorpusOutcome) int {
	for i, e := range errs {
		if e.Field != want.Field || e.Code != want.Code {
			continue
		}
		if want.Message == "" || e.Message == want.Message {
			return i
		}
	}
	return -1
}

func writeOutcomes(b *strings.Builder, label string, outcomes []syncvalidation.CorpusOutcome) {
	fmt.Fprintf(b, "%s:\n", label)
	if len(outcomes) == 0 {
		b.WriteString("    (nothing)\n")
		return
	}
	for _, o := range outcomes {
		fmt.Fprintf(b, "    %s\n", o)
	}
}

func writeFieldErrors(b *strings.Builder, label string, errs []FieldError) {
	fmt.Fprintf(b, "%s:\n", label)
	if len(errs) == 0 {
		b.WriteString("    (nothing — it accepted the op)\n")
		return
	}
	for _, e := range errs {
		fmt.Fprintf(b, "    %s  %s  %q\n", e.Field, e.Code, e.Message)
	}
}
