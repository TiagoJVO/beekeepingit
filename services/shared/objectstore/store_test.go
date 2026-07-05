package objectstore_test

import (
	"bytes"
	"context"
	"io"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	tcminio "github.com/testcontainers/testcontainers-go/modules/minio"
	"github.com/testcontainers/testcontainers-go/wait"

	"github.com/TiagoJVO/beekeepingit/services/shared/objectstore"
)

// TestStore_PutGetDelete proves the adapter works end-to-end against a real
// S3-compatible endpoint. It only ever constructs the Store from a Config —
// pointing it at a different S3-compatible provider (see ../README.md) needs
// no code change here, just different Config values.
func TestStore_PutGetDelete(t *testing.T) {
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
