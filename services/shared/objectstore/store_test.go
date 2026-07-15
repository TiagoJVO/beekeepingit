package objectstore_test

import (
	"bytes"
	"context"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	tcminio "github.com/testcontainers/testcontainers-go/modules/minio"
	"github.com/testcontainers/testcontainers-go/wait"

	"github.com/TiagoJVO/beekeepingit/services/shared/objectstore"
)

// newTestStore starts a MinIO test container and returns a Store connected
// to it. Factored out of TestStore_PutGetDelete so other tests (e.g. the
// EnsureBucket concurrency test below) can get a real S3-compatible backend
// without duplicating the container-setup boilerplate.
func newTestStore(t *testing.T) *objectstore.Store {
	t.Helper()
	ctx := context.Background()

	// The minio module's default wait strategy is wait.ForHTTP("/minio/health/live"):
	// liveness returns 200 as soon as the HTTP listener is up, which is *before* the
	// object layer finishes initializing. Under CI load the test then races ahead and
	// the S3 API answers "Server not initialized yet, please try again". Override with
	// the /minio/health/ready (readiness) endpoint, which only returns 200 once the
	// server can actually serve requests.
	container, err := tcminio.Run(ctx, "minio/minio:RELEASE.2025-04-08T15-41-24Z",
		testcontainers.WithWaitStrategy(
			wait.ForHTTP("/minio/health/ready").
				WithPort("9000/tcp").
				WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
		t.Fatalf("start minio container: %v", err)
	}
	t.Cleanup(func() {
		if err := container.Terminate(ctx); err != nil {
			t.Logf("terminate minio container: %v", err)
		}
	})

	endpoint, err := container.ConnectionString(ctx)
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}

	store, err := objectstore.New(objectstore.Config{
		Endpoint:  endpoint,
		AccessKey: container.Username,
		SecretKey: container.Password,
		UseSSL:    false,
	})
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

// TestStore_PutGetDelete proves the adapter works end-to-end against a real
// S3-compatible endpoint. It only ever constructs the Store from a Config —
// pointing it at a different S3-compatible provider (see ../README.md) needs
// no code change here, just different Config values.
func TestStore_PutGetDelete(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	const bucket = "beekeepingit-test"
	// Belt-and-suspenders around the readiness gate: the very first S3 call can still
	// briefly race the server's initialization under heavy CI load, so retry it with a
	// short backoff before treating an error as a real failure. Subsequent calls below
	// exercise the adapter without retries.
	if err := retry(t, func() error { return store.EnsureBucket(ctx, bucket) }); err != nil {
		t.Fatalf("ensure bucket: %v", err)
	}
	// EnsureBucket must be idempotent.
	if err := store.EnsureBucket(ctx, bucket); err != nil {
		t.Fatalf("ensure bucket (second call): %v", err)
	}

	const key = "hello.txt"
	want := []byte("hello beekeeping")
	if err := store.Put(ctx, bucket, key, bytes.NewReader(want), int64(len(want)), "text/plain"); err != nil {
		t.Fatalf("put: %v", err)
	}

	r, err := store.Get(ctx, bucket, key)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	got, err := io.ReadAll(r)
	_ = r.Close()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("got %q, want %q", got, want)
	}

	if err := store.Delete(ctx, bucket, key); err != nil {
		t.Fatalf("delete: %v", err)
	}
	// minio-go's GetObject is lazy: the "not found" error only surfaces on
	// first read, not on the GetObject call itself.
	deletedObj, err := store.Get(ctx, bucket, key)
	if err != nil {
		t.Fatalf("get (deleted object): %v", err)
	}
	defer deletedObj.Close()
	if _, err := io.ReadAll(deletedObj); err == nil {
		t.Fatal("expected error reading deleted object, got nil")
	}
}

// TestEnsureBucket_ConcurrentCallsAllSucceed is the regression test for
// HIGH #1: EnsureBucket's old implementation checked BucketExists then
// called MakeBucket as two separate round trips, not atomically. When two
// callers race — both see "doesn't exist", both call MakeBucket — the loser
// gets MinIO's native "BucketAlreadyOwnedByYou"/"BucketAlreadyExists" error
// back as a hard failure, even though EnsureBucket is documented as
// idempotent. This drives many goroutines at a fresh bucket name
// concurrently (via a start barrier, so they race on network latency rather
// than serialize) against a real MinIO backend — against the pre-fix code
// this reliably surfaces the race as a real error from at least one
// goroutine; the fix (attempt MakeBucket unconditionally, treat the
// already-exists error codes as success) must make every call succeed.
func TestEnsureBucket_ConcurrentCallsAllSucceed(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	// Warm up past MinIO's brief post-startup "not initialized yet" window
	// (see the comment in newTestStore) so the concurrent calls below race
	// on a real "does this bucket exist" question, not on server startup.
	if err := retry(t, func() error { return store.EnsureBucket(ctx, "warmup") }); err != nil {
		t.Fatalf("warm up: %v", err)
	}

	const bucket = "beekeepingit-concurrent-test"
	const goroutines = 10

	var wg sync.WaitGroup
	start := make(chan struct{})
	errs := make([]error, goroutines)
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			errs[i] = store.EnsureBucket(ctx, bucket)
		}(i)
	}
	close(start)
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: EnsureBucket() error = %v, want nil (a TOCTOU race between BucketExists and MakeBucket must not surface as a hard error)", i, err)
		}
	}
}

// retry runs fn until it succeeds or a short deadline elapses, backing off between
// attempts. It exists to absorb the transient "Server not initialized yet" error the
// MinIO server can return for the first request or two right after startup.
func retry(t *testing.T, fn func() error) error {
	t.Helper()
	const attempts = 10
	var err error
	for i := 0; i < attempts; i++ {
		if err = fn(); err == nil {
			return nil
		}
		t.Logf("attempt %d/%d failed, retrying: %v", i+1, attempts, err)
		time.Sleep(500 * time.Millisecond)
	}
	return err
}
