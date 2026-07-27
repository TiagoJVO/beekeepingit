package objectstore

import (
	"context"
	"fmt"
	"io"

	"github.com/minio/minio-go/v7"
)

// EnsureBucket creates bucket if it doesn't already exist. Idempotent —
// including under concurrent callers.
//
// This deliberately does NOT check BucketExists first: that would be a
// separate round trip from the MakeBucket call, so two concurrent callers
// could both observe "doesn't exist" and both proceed to MakeBucket, with
// one getting a hard "already exists" failure instead of the idempotent
// success EnsureBucket promises (a TOCTOU race). Instead, attempt MakeBucket
// unconditionally and treat the provider's own "already owned/exists"
// response as success — that check-and-create is atomic on the server side.
func (s *Store) EnsureBucket(ctx context.Context, bucket string) error {
	err := s.client.MakeBucket(ctx, bucket, minio.MakeBucketOptions{Region: ""})
	if err == nil {
		return nil
	}
	if resp := minio.ToErrorResponse(err); resp.Code == "BucketAlreadyOwnedByYou" || resp.Code == "BucketAlreadyExists" {
		return nil
	}
	return fmt.Errorf("objectstore: ensure bucket %q: %w", bucket, err)
}

// Put uploads the contents of r as bucket/key.
func (s *Store) Put(ctx context.Context, bucket, key string, r io.Reader, size int64, contentType string) error {
	_, err := s.client.PutObject(ctx, bucket, key, r, size, minio.PutObjectOptions{ContentType: contentType})
	if err != nil {
		return fmt.Errorf("objectstore: put %s/%s: %w", bucket, key, err)
	}
	return nil
}

// Get returns a reader for bucket/key. The caller must Close it.
func (s *Store) Get(ctx context.Context, bucket, key string) (io.ReadCloser, error) {
	obj, err := s.client.GetObject(ctx, bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, fmt.Errorf("objectstore: get %s/%s: %w", bucket, key, err)
	}
	return obj, nil
}

// Delete removes bucket/key.
func (s *Store) Delete(ctx context.Context, bucket, key string) error {
	if err := s.client.RemoveObject(ctx, bucket, key, minio.RemoveObjectOptions{}); err != nil {
		return fmt.Errorf("objectstore: delete %s/%s: %w", bucket, key, err)
	}
	return nil
}
