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
