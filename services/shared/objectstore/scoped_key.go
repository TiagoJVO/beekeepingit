package objectstore

import (
	"fmt"
	"path"
	"strings"
)

// ScopedKey namespaces key under organizationID so every caller composes
// tenant-safe keys the same way instead of hand-rolling prefixes. Put/Get/
// Delete/EnsureBucket take fully caller-supplied bucket/key strings with no
// organization_id enforcement of their own (NFR-ARC-2) — callers MUST run
// every object key through ScopedKey before passing it to those methods, so
// a missing/forgotten prefix can never let one tenant read or write
// another's objects.
//
// It rejects an empty organizationID (nothing to scope under) and any key
// containing a ".." path segment or that reduces to just the root (an empty
// key). A leading slash is tolerated and stripped, matching path.Clean's
// normalization.
//
// The ".." check runs on the RAW key, before path.Clean: for a rooted path,
// Clean always resolves/absorbs leading ".." segments (a path can't go
// above "/"), so checking the cleaned string for ".." would never catch a
// genuine traversal attempt like "../../etc/passwd" — Clean("/" +
// "../../etc/passwd") already comes out ".."-free. Rejecting outright on
// the raw key, rather than silently normalizing it away, is deliberate:
// a caller passing a traversal-shaped key is a bug worth surfacing, not
// something to paper over.
func ScopedKey(organizationID, key string) (string, error) {
	if organizationID == "" {
		return "", fmt.Errorf("objectstore: organizationID is required")
	}
	for _, segment := range strings.Split(key, "/") {
		if segment == ".." {
			return "", fmt.Errorf("objectstore: invalid key %q", key)
		}
	}
	clean := path.Clean("/" + key)
	if clean == "/" {
		return "", fmt.Errorf("objectstore: invalid key %q", key)
	}
	return organizationID + clean, nil
}
