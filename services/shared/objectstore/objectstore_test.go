package objectstore_test

import (
	"strings"
	"testing"

	"github.com/TiagoJVO/beekeepingit/services/shared/objectstore"
)

// TestNew_InvalidConfig proves New fails fast on a missing required field —
// without ever attempting a network call — so it needs no MinIO instance.
func TestNew_InvalidConfig(t *testing.T) {
	tests := []struct {
		name string
		cfg  objectstore.Config
	}{
		{name: "missing endpoint", cfg: objectstore.Config{AccessKey: "a", SecretKey: "s"}},
		{name: "missing access key", cfg: objectstore.Config{Endpoint: "e", SecretKey: "s"}},
		{name: "missing secret key", cfg: objectstore.Config{Endpoint: "e", AccessKey: "a"}},
		{name: "zero value", cfg: objectstore.Config{}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := objectstore.New(tt.cfg)
			if err == nil {
				t.Fatal("expected error, got nil")
			}
			if !strings.Contains(err.Error(), "required") {
				t.Errorf("error = %q, want it to mention required fields", err.Error())
			}
		})
	}
}

// TestNew_ValidConfig proves construction succeeds without any network call
// for a well-formed Config (New only builds the client; it doesn't connect).
func TestNew_ValidConfig(t *testing.T) {
	store, err := objectstore.New(objectstore.Config{
		Endpoint:  "minio.example.internal:9000",
		AccessKey: "access",
		SecretKey: "secret",
		UseSSL:    true,
		Region:    "eu-central-1",
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	if store == nil {
		t.Fatal("New() returned nil store with nil error")
	}
}
