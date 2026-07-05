// Package logging wires the shared service template's structured logging:
// JSON to stdout (readable via kubectl logs without a collector), fanned
// out to the OTel Logs SDK so records also reach the OTel collector
// (NFR-OBS-1), with trace_id/span_id attributes correlating each line to
// its OTel span — the field Grafana's Loki<->Tempo correlation keys off.
package logging

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	chimiddleware "github.com/go-chi/chi/v5/middleware"
	"go.opentelemetry.io/contrib/bridges/otelslog"
	otellog "go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/trace"

	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
)

type ctxKey struct{}

// NewLogger builds a *slog.Logger that writes JSON to stdout at cfg.LogLevel
// and forwards every record to lp (the OTel LoggerProvider from otelboot),
// with trace correlation applied to every record.
func NewLogger(cfg config.Config, lp otellog.LoggerProvider) *slog.Logger {
	stdout := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})
	bridge := otelslog.NewHandler(cfg.ServiceName, otelslog.WithLoggerProvider(lp))
	return slog.New(&traceHandler{Handler: newMultiHandler(stdout, bridge)})
}

// traceHandler wraps a slog.Handler so every record handled while a valid
// span is present in ctx gets trace_id/span_id attributes attached.
type traceHandler struct {
	slog.Handler
}

func (t *traceHandler) Handle(ctx context.Context, record slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		record.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return t.Handler.Handle(ctx, record)
}

func (t *traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &traceHandler{Handler: t.Handler.WithAttrs(attrs)}
}

func (t *traceHandler) WithGroup(name string) slog.Handler {
	return &traceHandler{Handler: t.Handler.WithGroup(name)}
}

// RequestLogger returns middleware that stores, in each request's context, a
// child logger carrying method/path/request_id fields, retrievable via
// FromContext by downstream handlers, and logs one line per completed
// request.
func RequestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			reqLogger := logger.With(
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
			)
			if id := chimiddleware.GetReqID(r.Context()); id != "" {
				reqLogger = reqLogger.With(slog.String("request_id", id))
			}
			ctx := context.WithValue(r.Context(), ctxKey{}, reqLogger)
			ww := chimiddleware.NewWrapResponseWriter(w, r.ProtoMajor)

			next.ServeHTTP(ww, r.WithContext(ctx))

			reqLogger.InfoContext(ctx, "request completed",
				slog.Int("status", ww.Status()),
				slog.Duration("duration", time.Since(start)),
			)
		})
	}
}

// FromContext returns the request-scoped logger stored by RequestLogger, or
// slog.Default() outside a request.
func FromContext(ctx context.Context) *slog.Logger {
	if l, ok := ctx.Value(ctxKey{}).(*slog.Logger); ok {
		return l
	}
	return slog.Default()
}
