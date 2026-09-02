// Package syncvalidation reads the shared sync-op validation description
// (contracts/validation/sync-ops.validation.json — docs/architecture/sync.md
// §9, D-12, FR-OF-2, #584).
//
// That file is the SINGLE definition of the mechanical rules each owning
// service's validate*Op enforces, and the offline client re-checks queued edits
// against it before pushing so a problem is caught on the device instead of
// arriving as a post-hoc rejection. The server stays authoritative — the client
// half is a UX optimization, not a security boundary — but that only holds if
// the description and the Go validators actually agree.
//
// This package exists so each owning service can bind its own constants to the
// description in an ordinary `go test` (services/*/api/sync_validation_test.go),
// turning "a hand-kept mirror" into "a mirror a build fails on". It is
// deliberately a *reader*, not an evaluator: the services keep enforcing their
// own rules in their own code, and the description is checked against them.
// The full case-by-case boundary contract tests — synthesizing an op per rule
// and asserting the service reports exactly that field and code — are #585's.
package syncvalidation

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

// RepoRelativePath is where the description lives, relative to the repository
// root. This package never takes a path from its caller — see [Load].
const RepoRelativePath = "contracts/validation/sync-ops.validation.json"

// pathFrom builds a repo-relative artifact's path from a package directory that
// sits depth levels below the repository root — e.g. services/apiaries/api is 3.
func pathFrom(depth int, repoRelative string) string {
	parts := make([]string, 0, depth+1)
	for range depth {
		parts = append(parts, "..")
	}
	parts = append(parts, filepath.FromSlash(repoRelative))
	return filepath.Join(parts...)
}

// Outcome is the (code, message) a failing check reports — the RFC 9457
// problem.FieldError halves that are not the field path.
type Outcome struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Ops is an entity's allowed op-kind set plus what an op outside it reports.
type Ops struct {
	Allowed []string `json:"allowed"`
	Outcome
}

// Check is one field-level rule.
//
// AllowNull applies to the shape kinds that read raw PRESENCE rather than the
// field's absence rule (today: jsonObject). Those kinds normally treat an
// explicit JSON `null` as present-but-wrong-shape, because that is what the
// server's `json.RawMessage` sees. AllowNull says the owning service accepts
// the literal for this field — which it must whenever a CLEARED value reaches
// the wire as a null, since PowerSync's column diff spells "this column is now
// null" that way (journeys' default_attributes, #385). Describing that per
// field rather than per kind is deliberate: activities' `attributes` is never
// cleared this way and still rejects the literal, and the corpus pins both.
type Check struct {
	Kind        string   `json:"kind"`
	On          []string `json:"on"`
	Limit       *float64 `json:"limit"`
	Min         *float64 `json:"min"`
	Max         *float64 `json:"max"`
	OnlyWithAll []string `json:"onlyWithAll"`
	AllowNull   bool     `json:"allowNull"`
	Outcome
}

// Field is one field of an entity's data object, and its checks.
type Field struct {
	Name       string  `json:"name"`
	AbsentWhen string  `json:"absentWhen"`
	Checks     []Check `json:"checks"`
}

// Check returns the field's check of the given kind, or nil.
func (f Field) Check(kind string) *Check {
	for i := range f.Checks {
		if f.Checks[i].Kind == kind {
			return &f.Checks[i]
		}
	}
	return nil
}

// EntityCheck is one rule spanning more than one field.
type EntityCheck struct {
	Kind        string   `json:"kind"`
	On          []string `json:"on"`
	Fields      []string `json:"fields"`
	ReportAs    string   `json:"reportAs"`
	WhenPresent string   `json:"whenPresent"`
	Require     string   `json:"require"`
	Outcome
}

// ReportPath is the op-relative field path a failing entity check is reported
// against: an explicit reportAs, else — for requiredWhenPresent, which always
// reports against the half that is MISSING rather than the half that triggered
// the rule — the field it requires, else `data` itself.
//
// That fallback is not this package's invention: the client's parser applies
// exactly the same one (client/lib/core/validation/sync_validation_rules.dart),
// which is precisely why it is restated here rather than left implicit — two
// independent readers deriving one path by convention is how a field path drifts
// (#585). The corpus is what keeps the two derivations equal in practice.
func (e EntityCheck) ReportPath() string {
	switch {
	case e.ReportAs != "":
		return "data." + e.ReportAs
	case e.Require != "":
		return "data." + e.Require
	default:
		return "data"
	}
}

// Entity is the described rule set for one wire entity_type.
type Entity struct {
	Source          string        `json:"source"`
	Ops             Ops           `json:"ops"`
	EntityTypeCheck *Outcome      `json:"entityTypeCheck"`
	Fields          []Field       `json:"fields"`
	EntityChecks    []EntityCheck `json:"entityChecks"`
}

// Field returns the named field's rules, or false if the description doesn't
// describe it (a field left entirely to the server).
func (e Entity) Field(name string) (Field, bool) {
	for _, f := range e.Fields {
		if f.Name == name {
			return f, true
		}
	}
	return Field{}, false
}

// FieldNames lists every field the description constrains, in order.
func (e Entity) FieldNames() []string {
	names := make([]string, 0, len(e.Fields))
	for _, f := range e.Fields {
		names = append(names, f.Name)
	}
	return names
}

// Limit returns the numeric limit the named field's check of kind carries
// (maxLength, maxBytes, min), and whether the description has that check at
// all. This is the drift-prone half of the mirror — the caps and bounds — so a
// service asserts its own constants against it.
func (e Entity) Limit(field, kind string) (float64, bool) {
	f, ok := e.Field(field)
	if !ok {
		return 0, false
	}
	c := f.Check(kind)
	if c == nil || c.Limit == nil {
		return 0, false
	}
	return *c.Limit, true
}

// Range returns the min/max a named field's "range" check carries.
func (e Entity) Range(field string) (minValue, maxValue float64, ok bool) {
	f, found := e.Field(field)
	if !found {
		return 0, 0, false
	}
	c := f.Check("range")
	if c == nil || c.Min == nil || c.Max == nil {
		return 0, 0, false
	}
	return *c.Min, *c.Max, true
}

// RequiredOn returns the op kinds the named field is described as required on.
// The put/patch split is the rule the client most easily gets wrong (#378: a
// patch is a partial update, so a put-only required field must not be demanded
// of it), which is why it is asserted explicitly rather than assumed.
func (e Entity) RequiredOn(field string) []string {
	f, ok := e.Field(field)
	if !ok {
		return nil
	}
	c := f.Check("required")
	if c == nil {
		return nil
	}
	return c.On
}

// UndescribedFields returns the fields the description constrains that are NOT
// among known — i.e. names that no longer exist on the service's wire struct.
// A rule against a field the server doesn't read is a rule the client enforces
// alone, which is the one direction that costs a user their edit.
func (e Entity) UndescribedFields(known []string) []string {
	index := make(map[string]bool, len(known))
	for _, k := range known {
		index[k] = true
	}
	var stale []string
	for _, name := range e.FieldNames() {
		if !index[name] {
			stale = append(stale, name)
		}
	}
	return stale
}

// JSONFieldNames lists the `json` tag names of a struct type — the wire field
// names an owning service's sync validator actually decodes.
func JSONFieldNames(t reflect.Type) []string {
	names := make([]string, 0, t.NumField())
	for i := range t.NumField() {
		tag, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		if tag != "" && tag != "-" {
			names = append(names, tag)
		}
	}
	return names
}

// Envelope holds the op-level checks every entity type shares.
type Envelope struct {
	ID        Outcome `json:"id"`
	UpdatedAt Outcome `json:"updatedAt"`
}

// Description is the whole document.
type Description struct {
	Version int `json:"version"`
	// ServerOnly records the rules deliberately NOT mirrored on the client, so
	// an omission reads as a decision rather than as an oversight.
	ServerOnly []string          `json:"serverOnly"`
	Envelope   Envelope          `json:"envelope"`
	Entities   map[string]Entity `json:"entities"`
}

// Entity returns the named entity's rules, failing loudly if the description
// doesn't carry it — a missing entity means the client silently validates
// nothing for it, which is exactly the drift this package exists to catch.
func (d Description) Entity(entityType string) (Entity, error) {
	e, ok := d.Entities[entityType]
	if !ok {
		return Entity{}, fmt.Errorf("validation description has no entity %q", entityType)
	}
	return e, nil
}

// Load reads and parses the description, resolved from a package directory
// that sits depth levels below the repository root (services/<svc>/api is 3).
//
// It takes a depth rather than a path on purpose: the only file this package
// may ever open is the committed description at [RepoRelativePath], and making
// that structural means no future caller can hand it a request-derived path and
// inherit the file-read suppression below.
func Load(depth int) (*Description, error) {
	raw, err := os.ReadFile(pathFrom(depth, RepoRelativePath)) //nolint:gosec // fixed repo-relative path, see doc
	if err != nil {
		return nil, fmt.Errorf("read validation description: %w", err)
	}
	var d Description
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("parse validation description: %w", err)
	}
	return &d, nil
}
