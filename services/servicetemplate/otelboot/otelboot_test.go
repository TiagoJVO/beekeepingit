package otelboot_test

import (
	"context"
	"testing"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/otelboot"
)

// The OTLP/gRPC exporters dial lazily, so Bootstrap must succeed even when
// the collector endpoint is unreachable — connectivity is only needed once
// telemetry is actually flushed, which these tests never trigger.
func testConfig() otelboot.Config {
	return otelboot.Config{
		ServiceName:       "example",
		ServiceNamespace:  "beekeepingit",
		CollectorEndpoint: "127.0.0.1:1", // deliberately unreachable
		Insecure:          true,
	}
}

func TestBootstrap_SucceedsAgainstUnreachableCollector(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	providers, err := otelboot.Bootstrap(ctx, testConfig())
	if err != nil {
		t.Fatalf("Bootstrap() error = %v, want nil (exporters must not dial eagerly)", err)
	}
	if providers.TracerProvider == nil || providers.MeterProvider == nil || providers.LoggerProvider == nil {
		t.Fatalf("Providers has a nil field: %+v", providers)
	}

	// Shutdown always attempts one final flush, which fails fast against an
	// unreachable collector — an error here is expected; what matters is
	// that Shutdown is bounded by its context and never hangs forever.
	done := make(chan error, 1)
	go func() {
		shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutCancel()
		done <- providers.Shutdown(shutCtx)
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Logf("Shutdown() returned %v (expected: no live collector at %s)", err, testConfig().CollectorEndpoint)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("Shutdown() did not return within 8s — providers are blocking forever on the unreachable collector")
	}
}
