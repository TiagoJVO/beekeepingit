package authn

import (
	"testing"
	"time"
)

// TestResolverCache_Expiry checks the per-instance cache honors its TTL,
// using an injected clock so it needs no sleeps.
func TestResolverCache_Expiry(t *testing.T) {
	now := time.Now()
	r := &resolver{
		ttl:   time.Minute,
		now:   func() time.Time { return now },
		cache: map[string]cacheEntry{},
	}

	r.set("sub-1", cacheEntry{userID: "u", orgID: "o", role: "admin", expiresAt: now.Add(time.Minute)})

	if _, ok := r.get("sub-1"); !ok {
		t.Fatal("want cache hit before expiry")
	}

	now = now.Add(2 * time.Minute) // advance past the entry's expiry
	if _, ok := r.get("sub-1"); ok {
		t.Fatal("want cache miss after expiry")
	}

	// Missing keys are a miss, not a panic.
	if _, ok := r.get("never-set"); ok {
		t.Fatal("want miss for unknown sub")
	}
}

// TestResolverCache_BoundedSize is a regression test for the per-instance
// sub→org cache growing unboundedly: it's only ever pruned lazily (on read,
// once an entry's TTL has passed), so a long-lived instance serving many
// distinct subjects would otherwise never shrink the map. A configured
// maxEntries caps it — once full, resolving a new subject evicts one
// existing entry instead of growing the map further.
func TestResolverCache_BoundedSize(t *testing.T) {
	now := time.Now()
	r := &resolver{
		ttl:        time.Minute,
		now:        func() time.Time { return now },
		cache:      map[string]cacheEntry{},
		maxEntries: 2,
	}

	r.set("sub-1", cacheEntry{userID: "u1", orgID: "o1", role: "admin", expiresAt: now.Add(time.Minute)})
	r.set("sub-2", cacheEntry{userID: "u2", orgID: "o2", role: "admin", expiresAt: now.Add(time.Minute)})
	r.set("sub-3", cacheEntry{userID: "u3", orgID: "o3", role: "admin", expiresAt: now.Add(time.Minute)})

	if len(r.cache) > 2 {
		t.Fatalf("cache size = %d, want <= 2 (bounded by maxEntries)", len(r.cache))
	}
	if _, ok := r.get("sub-3"); !ok {
		t.Fatal("want the just-set entry present after eviction made room for it")
	}
}

// TestResolverCache_BoundedSize_UpdatingExistingKeyDoesNotEvict proves the
// bound only kicks in for a genuinely new subject — refreshing an existing
// cached subject's entry must not evict anything (or itself).
func TestResolverCache_BoundedSize_UpdatingExistingKeyDoesNotEvict(t *testing.T) {
	now := time.Now()
	r := &resolver{
		ttl:        time.Minute,
		now:        func() time.Time { return now },
		cache:      map[string]cacheEntry{},
		maxEntries: 2,
	}

	r.set("sub-1", cacheEntry{userID: "u1", expiresAt: now.Add(time.Minute)})
	r.set("sub-2", cacheEntry{userID: "u2", expiresAt: now.Add(time.Minute)})
	r.set("sub-1", cacheEntry{userID: "u1-updated", expiresAt: now.Add(time.Minute)})

	if len(r.cache) != 2 {
		t.Fatalf("cache size = %d, want 2 (updating an existing key must not evict)", len(r.cache))
	}
	e, ok := r.get("sub-1")
	if !ok || e.userID != "u1-updated" {
		t.Errorf("get(sub-1) = %+v, %v, want the updated entry present", e, ok)
	}
	if _, ok := r.get("sub-2"); !ok {
		t.Error("want sub-2 still present")
	}
}
