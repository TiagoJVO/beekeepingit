package syncvalidation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// CorpusRepoRelativePath is where the shared boundary-contract corpus lives,
// relative to the repository root (#585).
//
// The corpus is the second half of the parity artifact: [RepoRelativePath]
// describes the rules, this file exercises them. Every case is a concrete wire
// op run through BOTH the owning service's real validate*Op and the client's
// real evaluator, so a rule the server quietly stopped applying, a drifted
// code/message/field-path string, and the two evaluators reading one declared
// rule differently are all a failing test rather than a field bug.
const CorpusRepoRelativePath = "contracts/validation/sync-ops.corpus.json"

// CorpusOutcome is one field error a case expects.
//
// Field is OP-RELATIVE (`data.name`, `op`, `id`) — the server prefixes it with
// `ops[i].`, and stripping that prefix is itself part of what the harness
// checks.
//
// An empty Message is a WILDCARD: the harness then matches on field and code
// alone. That is allowed only for [CorpusCase.ServerOnly], whose messages are
// not mirrored in the description and would otherwise make the corpus break
// whenever an unrelated vocabulary grows — a [CorpusCase.Expect] entry must pin
// its message, and TestCorpusExpectationsPinTheirMessage enforces that, since
// the Dart harness compares it verbatim either way.
type CorpusOutcome struct {
	Field   string `json:"field"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Why     string `json:"why"`
}

// String renders one outcome for a failure message.
func (o CorpusOutcome) String() string {
	if o.Message == "" {
		return fmt.Sprintf("%s  %s  (any message)", o.Field, o.Code)
	}
	return fmt.Sprintf("%s  %s  %q", o.Field, o.Code, o.Message)
}

// CorpusCase is one op and what each side must make of it.
type CorpusCase struct {
	Name string `json:"name"`
	Why  string `json:"why"`
	// EntityType routes the case to its owning service's validator. It is
	// deliberately NOT read from the op, so a case can carry a wrong
	// `entity_type` on the wire and still reach the right validator.
	EntityType string `json:"entityType"`
	// Op is the wire op, before [ExpandCorpusOp] resolves its @repeat markers.
	Op json.RawMessage `json:"op"`
	// Expect is what BOTH sides must report — and nothing else. Empty means
	// both sides must accept the op.
	Expect []CorpusOutcome `json:"expect"`
	// ServerOnly is what ONLY the authoritative server reports. The client must
	// report none of these.
	ServerOnly []CorpusOutcome `json:"serverOnly"`
}

// ServerExpectation is everything the owning service must report for this case.
func (c CorpusCase) ServerExpectation() []CorpusOutcome {
	out := make([]CorpusOutcome, 0, len(c.Expect)+len(c.ServerOnly))
	out = append(out, c.Expect...)
	return append(out, c.ServerOnly...)
}

// Corpus is the whole document.
type Corpus struct {
	Version int          `json:"version"`
	Cases   []CorpusCase `json:"cases"`
}

// For returns the cases owned by any of entityTypes, in corpus order.
func (c Corpus) For(entityTypes ...string) []CorpusCase {
	wanted := make(map[string]bool, len(entityTypes))
	for _, e := range entityTypes {
		wanted[e] = true
	}
	var out []CorpusCase
	for _, kase := range c.Cases {
		if wanted[kase.EntityType] {
			out = append(out, kase)
		}
	}
	return out
}

// EntityTypes lists every entity type the corpus carries a case for.
func (c Corpus) EntityTypes() map[string]bool {
	out := map[string]bool{}
	for _, kase := range c.Cases {
		out[kase.EntityType] = true
	}
	return out
}

// LoadCorpus reads and parses the corpus, resolved from a package directory
// depth levels below the repository root (services/<svc>/api is 3), with the
// same fixed-path discipline as [Load].
func LoadCorpus(depth int) (*Corpus, error) {
	raw, err := os.ReadFile(corpusPathFrom(depth)) //nolint:gosec // fixed repo-relative path, see Load
	if err != nil {
		return nil, fmt.Errorf("read validation corpus: %w", err)
	}
	var c Corpus
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("parse validation corpus: %w", err)
	}
	if len(c.Cases) == 0 {
		return nil, fmt.Errorf("validation corpus %s carries no cases", CorpusRepoRelativePath)
	}
	seen := make(map[string]bool, len(c.Cases))
	for _, kase := range c.Cases {
		if seen[kase.Name] {
			return nil, fmt.Errorf("validation corpus has two cases named %q", kase.Name)
		}
		seen[kase.Name] = true
	}
	return &c, nil
}

func corpusPathFrom(depth int) string {
	return pathFrom(depth, CorpusRepoRelativePath)
}

// repeatPrefix introduces the corpus's one string macro, "@repeat:<count>:<unit>",
// which expands to unit repeated count times. It exists so a 10001-character
// notes field does not have to be spelled out in the artifact; both sides
// implement the same three lines, and a mismatch between them shows up as a
// failing case rather than as a silent difference in what was tested.
const repeatPrefix = "@repeat:"

// maxRepeatCount bounds the macro so a typo cannot allocate the test host's
// memory. The largest cap any described rule carries is 10000.
const maxRepeatCount = 100_000

// ExpandCorpusOp resolves a case's @repeat markers and re-encodes the op in the
// canonical, compact form a device actually puts on the wire.
//
// Canonicalising matters for the one rule measured in raw bytes
// (journeys' default_attributes maxBytes): the committed corpus is
// pretty-printed by the repo's formatter, and the client encodes compactly, so
// comparing the two sides against the file's own bytes would compare different
// things. HTML escaping is disabled for the same reason — Go escapes < > and &
// by default and Dart does not.
func ExpandCorpusOp(op json.RawMessage) ([]byte, error) {
	var decoded any
	if err := json.Unmarshal(op, &decoded); err != nil {
		return nil, fmt.Errorf("decode corpus op: %w", err)
	}
	expanded, err := expandRepeats(decoded)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(expanded); err != nil {
		return nil, fmt.Errorf("re-encode corpus op: %w", err)
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

func expandRepeats(value any) (any, error) {
	switch v := value.(type) {
	case string:
		return expandRepeatString(v)
	case []any:
		for i, item := range v {
			expanded, err := expandRepeats(item)
			if err != nil {
				return nil, err
			}
			v[i] = expanded
		}
		return v, nil
	case map[string]any:
		for key, item := range v {
			expanded, err := expandRepeats(item)
			if err != nil {
				return nil, err
			}
			v[key] = expanded
		}
		return v, nil
	default:
		return value, nil
	}
}

func expandRepeatString(value string) (string, error) {
	rest, ok := strings.CutPrefix(value, repeatPrefix)
	if !ok {
		return value, nil
	}
	countText, unit, ok := strings.Cut(rest, ":")
	if !ok {
		return "", fmt.Errorf("malformed corpus macro %q: want %s<count>:<unit>", value, repeatPrefix)
	}
	count, err := strconv.Atoi(countText)
	if err != nil || count < 0 || count > maxRepeatCount {
		return "", fmt.Errorf("malformed corpus macro %q: count must be an integer in [0, %d]", value, maxRepeatCount)
	}
	return strings.Repeat(unit, count), nil
}
