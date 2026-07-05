package logging

import (
	"context"
	"log/slog"
)

// multiHandler fans a record out to every child Handler — e.g. a JSON
// handler writing to stdout and an OTel bridge handler forwarding to the
// collector — so a single *slog.Logger satisfies both without either
// consumer knowing about the other.
type multiHandler struct {
	handlers []slog.Handler
}

func newMultiHandler(handlers ...slog.Handler) *multiHandler {
	return &multiHandler{handlers: handlers}
}

func (m *multiHandler) Enabled(ctx context.Context, level slog.Level) bool {
	for _, h := range m.handlers {
		if h.Enabled(ctx, level) {
			return true
		}
	}
	return false
}

func (m *multiHandler) Handle(ctx context.Context, record slog.Record) error {
	var firstErr error
	for _, h := range m.handlers {
		if !h.Enabled(ctx, record.Level) {
			continue
		}
		if err := h.Handle(ctx, record.Clone()); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (m *multiHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	next := make([]slog.Handler, len(m.handlers))
	for i, h := range m.handlers {
		next[i] = h.WithAttrs(attrs)
	}
	return &multiHandler{handlers: next}
}

func (m *multiHandler) WithGroup(name string) slog.Handler {
	next := make([]slog.Handler, len(m.handlers))
	for i, h := range m.handlers {
		next[i] = h.WithGroup(name)
	}
	return &multiHandler{handlers: next}
}
