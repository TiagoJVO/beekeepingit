package objectstore_test

import (
	"bytes"
	"context"
	"io"
	"testing"

	tcminio "github.com/testcontainers/testcontainers-go/modules/minio"

	"github.com/TiagoJVO/beekeepingit/services/shared/objectstore"
)

// TestStore_PutGetDelete proves the adapter works end-to-end against a real
// S3-compatible endpoint. It only ever constructs the Store from a Config —
// pointing it at a different S3-compatible provider (see ../README.md) needs
// no code change here, just different Config values.
func TestStore_PutGetDelete(t *testing.T) {
	ctx := context.Background()

	container, err := tcminio.Run(ctx, "minio/minio:RELEASE.2025-04-08T15-41-24Z")
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
	if err := store.EnsureBucket(ctx, bucket); err != nil {
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
