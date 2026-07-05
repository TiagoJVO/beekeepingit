package logging

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"testing"

	"go.opentelemetry.io/otel/trace"
)

func TestTraceHandler_AddsTraceAndSpanID(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(&traceHandler{Handler: slog.NewJSONHandler(&buf, nil)})

	traceID, _ := trace.TraceIDFromHex("4bf92f3577b34da6a3ce929d0e0e4736")
	spanID, _ := trace.SpanIDFromHex("00f067aa0ba902b7")
	sc := trace.NewSpanContext(trace.SpanContextConfig{TraceID: traceID, SpanID: spanID, TraceFlags: trace.FlagsSampled})
	ctx := trace.ContextWithSpanContext(context.Background(), sc)

	logger.InfoContext(ctx, "hello")

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("decode log line: %v", err)
	}
	if got["trace_id"] != traceID.String() {
		t.Errorf("trace_id = %v, want %v", got["trace_id"], traceID.String())
	}
	if got["span_id"] != spanID.String() {
		t.Errorf("span_id = %v, want %v", got["span_id"], spanID.String())
	}
}

func TestTraceHandler_OmittedWithoutSpan(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(&traceHandler{Handler: slog.NewJSONHandler(&buf, nil)})

	logger.Info("no span here")

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("decode log line: %v", err)
	}
	if _, ok := got["trace_id"]; ok {
		t.Errorf("trace_id present without an active span: %v", got)
	}
}

type recordingHandler struct {
	calls int
	err   error
}

func (h *recordingHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *recordingHandler) Handle(context.Context, slog.Record) error {
	h.calls++
	return h.err
}
func (h *recordingHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *recordingHandler) WithGroup(string) slog.Handler      { return h }

func TestMultiHandler_FansOutToAllChildren(t *testing.T) {
	a := &recordingHandler{}
	b := &recordingHandler{}
	logger := slog.New(newMultiHandler(a, b))

	logger.Info("fan out")

	if a.calls != 1 || b.calls != 1 {
		t.Errorf("calls = (%d, %d), want (1, 1)", a.calls, b.calls)
	}
}

func TestMultiHandler_ReturnsFirstError(t *testing.T) {
	boom := errors.New("boom")
	a := &recordingHandler{err: boom}
	b := &recordingHandler{}

	err := newMultiHandler(a, b).Handle(context.Background(), slog.Record{})
	if !errors.Is(err, boom) {
		t.Errorf("Handle() error = %v, want %v", err, boom)
	}
}
