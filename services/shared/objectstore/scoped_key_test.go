package objectstore_test

import (
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/objectstore"
)

// TestScopedKey_MissingOrganizationID_Errors is the regression test for
// CRITICAL #2 (no tenancy-scoping guardrail): Put/Get/Delete/EnsureBucket
// take fully caller-supplied bucket/key strings with no organization_id
// enforcement, so a caller that forgets to namespace a key can read/write
// another tenant's objects. ScopedKey is the tenant-safe key-composition
// helper every caller should use instead of hand-rolling prefixes; it must
// refuse to build a key when organizationID is empty rather than silently
// producing an unscoped (org-less) key.
func TestScopedKey_MissingOrganizationID_Errors(t *testing.T) {
	_, err := objectstore.ScopedKey("", "photos/a.jpg")
	if err == nil {
		t.Fatal("ScopedKey(\"\", ...) error = nil, want a non-nil error")
	}
}

// TestScopedKey_PathTraversal_Errors proves a key trying to escape its
// organization's namespace via ".." is rejected, not silently normalized
// into a path outside organizationID.
func TestScopedKey_PathTraversal_Errors(t *testing.T) {
	tests := []string{
		"../../etc/passwd",
		"photos/../../other-org/secret.jpg",
		"..",
		"a/../../b",
	}
	for _, key := range tests {
		t.Run(key, func(t *testing.T) {
			_, err := objectstore.ScopedKey("org-123", key)
			if err == nil {
				t.Fatalf("ScopedKey(%q, %q) error = nil, want a non-nil error", "org-123", key)
			}
		})
	}
}

// TestScopedKey_EmptyKey_Errors proves a key that cleans down to just the
// root ("" or "/") is rejected rather than producing a key that's just the
// organization prefix with nothing under it.
func TestScopedKey_EmptyKey_Errors(t *testing.T) {
	for _, key := range []string{"", "/", "//"} {
		t.Run("key="+key, func(t *testing.T) {
			_, err := objectstore.ScopedKey("org-123", key)
			if err == nil {
				t.Fatalf("ScopedKey(%q, %q) error = nil, want a non-nil error", "org-123", key)
			}
		})
	}
}

// TestScopedKey_Valid_NamespacesUnderOrganizationID proves the happy path:
// a normal key is namespaced under organizationID with a single separating
// slash.
func TestScopedKey_Valid_NamespacesUnderOrganizationID(t *testing.T) {
	got, err := objectstore.ScopedKey("org-123", "photos/a.jpg")
	if err != nil {
		t.Fatalf("ScopedKey() error = %v, want nil", err)
	}
	want := "org-123/photos/a.jpg"
	if got != want {
		t.Fatalf("ScopedKey() = %q, want %q", got, want)
	}
}

// TestScopedKey_Valid_LeadingSlashIsTolerated proves a caller-supplied key
// with a leading slash is normalized the same way as one without.
func TestScopedKey_Valid_LeadingSlashIsTolerated(t *testing.T) {
	got, err := objectstore.ScopedKey("org-123", "/photos/a.jpg")
	if err != nil {
		t.Fatalf("ScopedKey() error = %v, want nil", err)
	}
	want := "org-123/photos/a.jpg"
	if got != want {
		t.Fatalf("ScopedKey() = %q, want %q", got, want)
	}
}

// TestScopedKey_DoesNotLeakOneOrgsKeyUnderAnother is a direct tenancy-guard
// proof: composing a key for one organizationID must never collide with (or
// fall under) a different organizationID's namespace.
func TestScopedKey_DoesNotLeakOneOrgsKeyUnderAnother(t *testing.T) {
	got, err := objectstore.ScopedKey("org-a", "shared/file.txt")
	if err != nil {
		t.Fatalf("ScopedKey() error = %v, want nil", err)
	}
	if strings.HasPrefix(got, "org-b") {
		t.Fatalf("ScopedKey() = %q, leaked under org-b's namespace", got)
	}
}
