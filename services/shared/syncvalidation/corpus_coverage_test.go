package syncvalidation_test

import (
	"fmt"
	"sort"
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation"
)

// These tests guard the CORPUS against the DESCRIPTION (#585). The per-service
// corpus tests and the client's twin run the corpus through the two real
// evaluators; nothing there would notice a rule that no case exercises at all,
// which is how a corpus quietly stops covering what it was built to cover.
//
// depth 3: this package sits at services/shared/syncvalidation.
const repoDepth = 3

// describedOutcome is one (entity, op-relative field, code) the description
// declares, with the message it declares for it.
type describedOutcome struct {
	entity string
	field  string
	code   string
}

func (d describedOutcome) String() string {
	return fmt.Sprintf("%s → %s (%s)", d.entity, d.field, d.code)
}

func TestCorpusExercisesEveryDescribedRule(t *testing.T) {
	described := describedOutcomes(t)
	corpus := loadCorpus(t)

	seen := map[describedOutcome]bool{}
	for _, kase := range corpus.Cases {
		for _, outcome := range kase.ServerExpectation() {
			seen[describedOutcome{entity: kase.EntityType, field: outcome.Field, code: outcome.Code}] = true
		}
	}

	var uncovered []string
	for key := range described {
		if !seen[key] {
			uncovered = append(uncovered, key.String())
		}
	}
	if len(uncovered) > 0 {
		sort.Strings(uncovered)
		t.Fatalf("%s describes rules no case in %s exercises, so nothing checks that either "+
			"evaluator still applies them:\n    %s\nAdd a case per rule — a description entry with no "+
			"case is a rule on trust, which is the thing this corpus exists to remove.",
			syncvalidation.RepoRelativePath, syncvalidation.CorpusRepoRelativePath,
			strings.Join(uncovered, "\n    "))
	}
}

func TestCorpusMessagesMatchTheDescription(t *testing.T) {
	described := describedOutcomes(t)
	corpus := loadCorpus(t)

	var drifted []string
	for _, kase := range corpus.Cases {
		for _, outcome := range kase.ServerExpectation() {
			key := describedOutcome{entity: kase.EntityType, field: outcome.Field, code: outcome.Code}
			want, ok := described[key]
			// Not described at all: a serverOnly rule (ownership, a vocabulary,
			// the attribute schema), whose message is the server's own business.
			if !ok || outcome.Message == "" {
				continue
			}
			if outcome.Message != want {
				drifted = append(drifted, fmt.Sprintf("%s\n        corpus:      %q\n        description: %q",
					key, outcome.Message, want))
			}
		}
	}
	if len(drifted) > 0 {
		sort.Strings(drifted)
		t.Fatalf("the corpus and %s disagree about the message a rule reports. The corpus is asserted "+
			"against the owning service's REAL validator, so the description is the side that is wrong "+
			"— the client ships that string to a beekeeper's device:\n    %s",
			syncvalidation.RepoRelativePath, strings.Join(drifted, "\n    "))
	}
}

func TestCorpusExpectationsPinTheirMessage(t *testing.T) {
	// A message-less outcome is a WILDCARD to the Go harness (match on field and
	// code alone), which is right for a serverOnly rule — its message is the
	// server's own business and pinning it would break this corpus whenever an
	// unrelated vocabulary grows. It is wrong for an `expect` entry: the message
	// is half of what the two sides must agree on, and the Dart harness compares
	// it verbatim regardless. Left unenforced, an omission would make the two
	// suites disagree about whether the corpus is even well-formed.
	for _, kase := range loadCorpus(t).Cases {
		for _, outcome := range kase.Expect {
			if outcome.Message == "" {
				t.Errorf("case %q expects %s with no message; an `expect` entry must pin the "+
					"message it asserts (only `serverOnly` entries may leave it out)",
					kase.Name, outcome.Field)
			}
		}
	}
}

func TestCorpusAcceptsAtLeastOneValidOpPerEntity(t *testing.T) {
	description := loadDescription(t)
	corpus := loadCorpus(t)

	accepted := map[string]bool{}
	for _, kase := range corpus.Cases {
		if len(kase.Expect) == 0 && len(kase.ServerOnly) == 0 {
			accepted[kase.EntityType] = true
		}
	}
	for entityType := range description.Entities {
		if !accepted[entityType] {
			t.Errorf("no corpus case has both sides ACCEPT a %s op — a corpus of nothing but "+
				"rejections would still pass with a validator that rejects everything", entityType)
		}
	}
}

func TestCorpusCoversEveryDescribedEntityType(t *testing.T) {
	description := loadDescription(t)
	present := loadCorpus(t).EntityTypes()

	for entityType := range description.Entities {
		if !present[entityType] {
			t.Errorf("the description carries rules for %q but the corpus has no case for it", entityType)
		}
	}
	for entityType := range present {
		if _, ok := description.Entities[entityType]; !ok {
			t.Errorf("the corpus has cases for %q, which the description does not describe", entityType)
		}
	}
}

func TestCorpusOpMacroExpandsTheWayTheClientExpandsIt(t *testing.T) {
	// The client re-implements these three lines in
	// client/test/core/validation/sync_op_corpus_test.dart; both sides pin the
	// same examples so the two expansions cannot quietly diverge and leave the
	// two evaluators testing different bytes.
	got, err := syncvalidation.ExpandCorpusOp([]byte(`{"a":"@repeat:3:ab","b":"plain","c":["@repeat:2:é"],"d":1}`))
	if err != nil {
		t.Fatalf("expand: %v", err)
	}
	const want = `{"a":"ababab","b":"plain","c":["éé"],"d":1}`
	if string(got) != want {
		t.Fatalf("expanded op = %s, want %s", got, want)
	}
}

func TestCorpusOpMacroRejectsAMalformedCount(t *testing.T) {
	if _, err := syncvalidation.ExpandCorpusOp([]byte(`{"a":"@repeat:many:x"}`)); err == nil {
		t.Fatal("a malformed @repeat macro must fail loudly, not expand to something arbitrary")
	}
}

func describedOutcomes(t *testing.T) map[describedOutcome]string {
	t.Helper()
	description := loadDescription(t)

	out := map[describedOutcome]string{}
	add := func(entity, field string, outcome syncvalidation.Outcome) {
		out[describedOutcome{entity: entity, field: field, code: outcome.Code}] = outcome.Message
	}
	for entityType, entity := range description.Entities {
		add(entityType, "op", entity.Ops.Outcome)
		add(entityType, "id", description.Envelope.ID)
		add(entityType, "updated_at", description.Envelope.UpdatedAt)
		if entity.EntityTypeCheck != nil {
			add(entityType, "entity_type", *entity.EntityTypeCheck)
		}
		for _, field := range entity.Fields {
			for _, check := range field.Checks {
				add(entityType, "data."+field.Name, check.Outcome)
			}
		}
		for _, check := range entity.EntityChecks {
			add(entityType, check.ReportPath(), check.Outcome)
		}
	}
	return out
}

func loadDescription(t *testing.T) *syncvalidation.Description {
	t.Helper()
	d, err := syncvalidation.Load(repoDepth)
	if err != nil {
		t.Fatalf("load shared validation description: %v", err)
	}
	return d
}

func loadCorpus(t *testing.T) *syncvalidation.Corpus {
	t.Helper()
	c, err := syncvalidation.LoadCorpus(repoDepth)
	if err != nil {
		t.Fatalf("load shared validation corpus: %v", err)
	}
	return c
}
