package objectstore

import (
	"context"
	"fmt"
	"io"

	"github.com/minio/minio-go/v7"
)

// EnsureBucket creates bucket if it doesn't already exist. Idempotent.
func (s *Store) EnsureBucket(ctx context.Context, bucket string) error {
	exists, err := s.client.BucketExists(ctx, bucket)
	if err != nil {
		return fmt.Errorf("objectstore: bucket exists check %q: %w", bucket, err)
	}
	if exists {
		return nil
	}

	if err := s.client.MakeBucket(ctx, bucket, minio.MakeBucketOptions{Region: ""}); err != nil {
		return fmt.Errorf("objectstore: make bucket %q: %w", bucket, err)
	}
	return nil
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
