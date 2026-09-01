// Package paritytest holds the assertions an owning service's own package tests
// use to bind its sync-validation constants to the shared description
// (contracts/validation/sync-ops.validation.json — docs/architecture/sync.md §9,
// D-12, FR-OF-2, #584).
//
// The offline client re-checks queued edits against that description before
// pushing, so a rule that drifts from the server's doesn't merely go unenforced
// — it can make the client reject an edit this service would have accepted, with
// no server to overrule it. Binding the description to each service's own
// constants turns that from a latent field bug into a failing `go test`.
//
// A separate package (rather than helpers on [syncvalidation]) so nothing that
// ships in a service binary imports `testing`, following the stdlib's own
// httptest/iotest convention.
package paritytest

import (
	"reflect"
	"slices"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/syncvalidation"
)

// Load reads the shared description from a package directory depth levels below
// the repository root (services/<svc>/api is 3).
func Load(t testing.TB, depth int) *syncvalidation.Description {
	t.Helper()
	d, err := syncvalidation.Load(syncvalidation.PathFrom(depth))
	if err != nil {
		t.Fatalf("load shared validation description: %v", err)
	}
	return d
}

// Entity returns the described rules for entityType, failing if absent — a
// missing entity means the client validates nothing at all for it.
func Entity(t testing.TB, d *syncvalidation.Description, entityType string) syncvalidation.Entity {
	t.Helper()
	e, err := d.Entity(entityType)
	if err != nil {
		t.Fatalf("%v", err)
	}
	return e
}

// AssertOps checks the described op-kind set matches what the service accepts.
func AssertOps(t testing.TB, e syncvalidation.Entity, want ...string) {
	t.Helper()
	if !slices.Equal(e.Ops.Allowed, want) {
		t.Fatalf("described op kinds = %v, this service accepts %v", e.Ops.Allowed, want)
	}
}

// AssertLimit checks a described numeric limit (maxLength, maxBytes, min)
// against the service's own constant.
func AssertLimit(t testing.TB, e syncvalidation.Entity, field, kind string, want float64) {
	t.Helper()
	got, ok := e.Limit(field, kind)
	if !ok {
		t.Fatalf("description has no %s check on %s", kind, field)
	}
	if got != want {
		t.Fatalf("described %s on %s = %v, this service enforces %v", kind, field, got, want)
	}
}

// AssertRange checks a described numeric range against the service's bounds.
func AssertRange(t testing.TB, e syncvalidation.Entity, field string, wantMin, wantMax float64) {
	t.Helper()
	lo, hi, ok := e.Range(field)
	if !ok || lo != wantMin || hi != wantMax {
		t.Fatalf("described %s range = (%v, %v, ok=%v), this service enforces (%v, %v)", field, lo, hi, ok, wantMin, wantMax)
	}
}

// AssertRequiredOn checks which op kinds a field is described as required on.
// This is the rule the client most easily gets wrong: a patch is a partial
// update, so demanding a put-only field of one rejects valid edits (#378).
func AssertRequiredOn(t testing.TB, e syncvalidation.Entity, field string, want ...string) {
	t.Helper()
	got := e.RequiredOn(field)
	if !slices.Equal(got, want) {
		t.Fatalf("described required-on for %s = %v, this service requires it on %v", field, got, want)
	}
}

// AssertNoVocabulary checks the description does NOT mirror a field's controlled
// vocabulary. These sets are server-owned and extensible (D-20), and a value from
// a newer release can reach an older client by down-sync and be re-uploaded — a
// frozen client copy would then reject it permanently.
func AssertNoVocabulary(t testing.TB, e syncvalidation.Entity, field string) {
	t.Helper()
	f, ok := e.Field(field)
	if ok && f.Check("enum") != nil {
		t.Fatalf("description mirrors the extensible %s vocabulary; it must not", field)
	}
}

// AssertDescribesOnlyWireFields fails if the description constrains a field this
// service's wire struct no longer decodes — a rule the client would then be
// enforcing alone.
func AssertDescribesOnlyWireFields(t testing.TB, e syncvalidation.Entity, wireShape any) {
	t.Helper()
	known := syncvalidation.JSONFieldNames(reflect.TypeOf(wireShape))
	if stale := e.UndescribedFields(known); len(stale) > 0 {
		t.Fatalf("description constrains fields this service does not decode: %v (wire fields: %v)", stale, known)
	}
}
