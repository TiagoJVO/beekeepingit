// Package objectstore is an S3-compatible object storage abstraction (NFR-ARC-2).
//
// The Store talks to MinIO today and to AWS S3 (or any other S3-compatible
// provider) later, purely by changing Config — minio-go/v7 is itself a
// generic S3 client, so no provider-specific code lives outside this
// package. See ../README.md for a worked example of switching endpoints.
package objectstore

import (
	"fmt"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Config holds the connection details for an S3-compatible endpoint.
// Populate it from environment/config/secrets — never hardcode credentials.
type Config struct {
	Endpoint  string // host:port, no scheme (e.g. "minio:9000")
	AccessKey string
	SecretKey string
	UseSSL    bool
	Region    string // optional; leave empty for providers that don't require one
}

// Store is an S3-compatible object storage client.
type Store struct {
	client *minio.Client
}

// New builds a Store from cfg. It performs no network calls itself — call
// EnsureBucket (or any other method) to exercise the connection.
func New(cfg Config) (*Store, error) {
	if cfg.Endpoint == "" || cfg.AccessKey == "" || cfg.SecretKey == "" {
		return nil, fmt.Errorf("objectstore: endpoint, access key and secret key are required")
	}

	client, err := minio.New(cfg.Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, ""),
		Secure: cfg.UseSSL,
		Region: cfg.Region,
	})
	if err != nil {
		return nil, fmt.Errorf("objectstore: new client: %w", err)
	}

	return &Store{client: client}, nil
}
