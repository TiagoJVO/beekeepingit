// Package otelboot bootstraps the OpenTelemetry SDK — traces, metrics, and
// logs — exporting via OTLP/gRPC to the in-cluster OTel Collector
// (docs/adr/0013-observability-stack.md, "otel-collector:4317"). The OTel Go
// Logs SDK (go.opentelemetry.io/otel/sdk/log, v0.x) is still pre-1.0 at the
// time this package was written; it is otherwise functionally complete and
// is what the collector's OTLP logs receiver already expects.
package otelboot

import (
	"context"
	"errors"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Config controls where telemetry is exported and how the emitting service
// identifies itself in Resource attributes.
type Config struct {
	ServiceName       string
	ServiceNamespace  string
	CollectorEndpoint string // host:port, e.g. "otel-collector:4317" in-cluster
	Insecure          bool   // no TLS to the collector (true for in-cluster/local dev)
}

// Providers holds the three OTel SDK providers, already registered as the
// global providers/propagator and ready for instrumentation (e.g.
// otelhttp) to use.
type Providers struct {
	TracerProvider *sdktrace.TracerProvider
	MeterProvider  *sdkmetric.MeterProvider
	LoggerProvider *sdklog.LoggerProvider
}

// shutdowner is satisfied by every OTel SDK provider Bootstrap creates —
// narrowed here so a partial-startup failure can clean up whichever
// providers were already built before the failure, regardless of type.
type shutdowner interface {
	Shutdown(ctx context.Context) error
}

// shutdownAll shuts down every non-nil provider in providers, joining any
// errors. Used both by Bootstrap's partial-startup cleanup and by
// Providers.Shutdown.
func shutdownAll(ctx context.Context, providers ...shutdowner) error {
	var errs []error
	for _, p := range providers {
		if p == nil {
			continue
		}
		if err := p.Shutdown(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) == 0 {
		return nil
	}
	return errors.Join(errs...)
}

// Bootstrap builds the Resource and the three OTLP-gRPC exporters/providers,
// registers the tracer/meter providers and a W3C tracecontext+baggage
// propagator globally, and returns Providers for the caller to pass to
// logging.NewLogger and to Shutdown on exit.
//
// If a later exporter/provider fails to start, every provider already
// created earlier in this call is shut down before the error is returned,
// so a partial startup failure never leaks a running provider (with its own
// background batching goroutines) that the caller has no reference to.
func Bootstrap(ctx context.Context, cfg Config) (_ *Providers, err error) {
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(cfg.ServiceName),
			semconv.ServiceNamespace(cfg.ServiceNamespace),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("otelboot: build resource: %w", err)
	}

	var created []shutdowner
	defer func() {
		if err != nil {
			if shutErr := shutdownAll(context.Background(), created...); shutErr != nil {
				err = errors.Join(err, fmt.Errorf("otelboot: shutting down partially-started providers: %w", shutErr))
			}
		}
	}()

	traceExp, err := otlptracegrpc.New(ctx, grpcOpts(cfg, otlptracegrpc.WithEndpoint, otlptracegrpc.WithInsecure)...)
	if err != nil {
		return nil, fmt.Errorf("otelboot: new trace exporter: %w", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
	)
	created = append(created, tp)

	metricExp, err := otlpmetricgrpc.New(ctx, grpcOpts(cfg, otlpmetricgrpc.WithEndpoint, otlpmetricgrpc.WithInsecure)...)
	if err != nil {
		return nil, fmt.Errorf("otelboot: new metric exporter: %w", err)
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp)),
		sdkmetric.WithResource(res),
	)
	created = append(created, mp)

	logExp, err := otlploggrpc.New(ctx, grpcOpts(cfg, otlploggrpc.WithEndpoint, otlploggrpc.WithInsecure)...)
	if err != nil {
		return nil, fmt.Errorf("otelboot: new log exporter: %w", err)
	}
	lp := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)),
		sdklog.WithResource(res),
	)
	created = append(created, lp)

	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	return &Providers{TracerProvider: tp, MeterProvider: mp, LoggerProvider: lp}, nil
}

// grpcOpts builds the [endpoint, insecure?] options shared by all three
// OTLP/gRPC exporter packages, each of which declares its own Option type.
func grpcOpts[Option any](cfg Config, withEndpoint func(string) Option, withInsecure func() Option) []Option {
	opts := []Option{withEndpoint(cfg.CollectorEndpoint)}
	if cfg.Insecure {
		opts = append(opts, withInsecure())
	}
	return opts
}

// Shutdown flushes and closes all three providers, joining any errors.
func (p *Providers) Shutdown(ctx context.Context) error {
	return errors.Join(
		p.TracerProvider.Shutdown(ctx),
		p.MeterProvider.Shutdown(ctx),
		p.LoggerProvider.Shutdown(ctx),
	)
}
